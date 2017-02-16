defmodule Farmbot.Logger do
  @moduledoc """
    Logger backend for logging to the frontend and dumping to the API.
    Takes messages that were logged useing Logger, if they can be
    jsonified, adds them too a buffer, when that buffer hits a certain
    size, it tries to dump the messages onto the API.
  """
  alias Farmbot.Sync
  alias Farmbot.HTTP
  use GenEvent
  require Logger

  @type state :: {[log_message], posting?}

  @spec init(any) :: {:ok, state}
  def init(_), do: {:ok, build_state()}

  # ten megs. i promise
  @max_file_size 1.0e+7

  # The example said ignore messages for other nodes, so im ignoring messages
  # for other nodes.
  def handle_event({_level, gl, {Logger, _, _, _}}, state)
    when node(gl) != node()
  do
    {:ok, state}
  end

  # Tehe
  def handle_event({l, f, {Logger, ">>" <> message, ts, meta}}, s) do
    device_name = Sync.device_name
    handle_event({l, f, {Logger, "#{device_name}" <> message, ts, meta}}, s)
  end

  # The logger event.
  def handle_event(
    {level, _, {Logger, message, timestamp, metadata}},
    {messages, posting?})
  do
    # if there is type key in the meta we need that to have priority
    relevent_meta = Keyword.take(metadata, [:type])
    type = parse_type(level, relevent_meta)

    # right now this will only ever be []
    # But eventually it will be sms, email, twitter, etc
    channels = parse_channels(Keyword.take(metadata, [:channels]))

    # BUG: should not be poling the bot for its position.
    # pos = BotState.get_current_pos
    pos = [-1,-2,-3]

    # take logger time stamp and spit out a unix timestamp for the javascripts.
    with({:ok, created_at} <- parse_created_at(timestamp),
         {:ok, san_m}      <- sanitize(message, metadata),
         {:ok, log}        <- build_log(san_m, created_at, type, channels, pos),
         :ok               <- emit(log),
         do: dispatch({messages ++ [log], posting?}))
    # if we got nil before, dont dispatch the new message into the buffer
    || dispatch({messages, posting?})
  end

  def handle_event(:flush, _state), do: {:ok, build_state()}

  # If the post succeeded, we clear the messages
  def handle_call(:post_success, {_, _}), do: {:ok, :ok, {[], false}}
  # If it did not succeed, keep the messages, and try again until it completes.
  def handle_call({:post_fail, _error}, {messages, _}) do
    {:ok, :ok, {messages, false}}
  end

  def handle_call(:messages, {messages, f}) do
    {:ok, messages, {messages, f}}
  end

  # Catch any stray calls.
  def handle_call(_, state), do: {:ok, :unhandled, state}
  def handle_info(_, state), do: dispatch state

  @spec terminate(any, state) :: no_return
  def terminate(_,_) do
    # if this backend crashes just pop it out of the logger backends.
    # if we don't do this it bacomes a huge mess because of Logger
    # trying to restart this module
    # then this module dying again
    # then printing a HUGE supervisor report
    # then Logger trying to add it again
    # etc
    Logger.remove_backend(__MODULE__)
  end

  @spec emit(map) :: :ok
  defp emit(msg), do: Farmbot.Transport.log(msg)

  # IF we are already posting messages to the api, no need to check the count.
  defp dispatch({messages, true}), do: {:ok, {messages, true}}
  # If we not already doing an HTTP Post to the api, check to see if we need to
  # (check if the count of messages is greater than 50)
  defp dispatch({messages, false}) do
    if Enum.count(messages) > 50 do
      pid = self() # var that = this;
      spawn fn() ->
        do_post(messages, pid)
      end
      {:ok, {messages, true}}
    else
      {:ok, {messages, false}}
    end
  end

  # Posts an array of logs to the API.
  @spec do_post([log_message],pid) :: :ok
  defp do_post(m, _pid) do
    {messages, _} = Enum.partition(m, fn(message) ->
      case Poison.encode(message) do
        {:ok, json} -> json
        _ ->  nil
      end
    end)
      str =
        messages
        |> Enum.map(fn(m) -> "#{m.created_at}: #{m.message}\n" end)
        |> List.to_string
    write_to_file(str)
    "/api/logs" |> HTTP.post(Poison.encode!(messages)) |> parse_resp
  end

  # Writes to a file in a transaction
  @spec write_to_file(binary) :: no_return
  defp write_to_file(str) do
    Farmbot.System.FS.transaction fn() ->
      path = Farmbot.System.FS.path <> "/log.txt"
      case File.stat(path) do
        # check the files size.
        {:ok, %File.Stat{size: s}} when s > @max_file_size ->
          File.write(path, "")
        # if the file is there, we are fine.
        {:ok, _stat} -> :ok
        # if its not there create it. I dont think we HAVE to do this.
        {:error, :enoent} -> File.write(path, "")
      end
      File.write(path, str, [:append])
    end
  end

  # Parses what the api sends back. Will only ever return :ok even if there was
  # an error.
  @spec parse_resp(any) :: :ok
  defp parse_resp(%HTTPoison.Response{status_code: 200}),
    do: GenEvent.call(Elixir.Logger, Farmbot.Logger, :post_success)
  defp parse_resp(error),
    do: GenEvent.call(Elixir.Logger, Farmbot.Logger, {:post_fail, error})

  @type rpc_log_type
    :: :success
     | :busy
     | :warn
     | :error
     | :info
     | :fun

  @type logger_level
    :: :info
     | :debug
     | :warn
     | :error

  @type channels :: :toast

  @type meta :: [] | [type: rpc_log_type]
  @type log_message
  :: %{message: String.t,
       channels: channels,
       created_at: integer,
       meta: %{
          type: rpc_log_type,
          x: integer,
          y: integer,
          z: integer}}

  # Translates Logger levels into Farmbot levels.
  # :info -> :info
  # :debug -> :info
  # :warn -> :warn
  # :error -> :error
  #
  # Also takes some meta.
  # Meta should take priority over
  # Logger Levels.
  @spec parse_type(logger_level, meta) :: rpc_log_type
  defp parse_type(:debug, []), do: :info
  defp parse_type(level, []), do: level
  defp parse_type(_level, [type: type]), do: type

  # can't jsonify tuples.
  defp parse_channels([channels: channels]), do: channels
  defp parse_channels(_), do: []

  @spec sanitize(binary, [any]) :: {:ok, String.t} | nil
  defp sanitize(message, meta) do
    m = Keyword.take(meta, [:module])
    if !meta[:nopub] do
      case m do
        # Fileter by module. This probably is slow
        [module: mod] -> filter_module(mod, message)
        [module: nil] -> filter_text(message)
        # anything else
        _ -> filter_text(message)
      end
    end
  end

  defp filter_module(:"Elixir.Nerves.InterimWiFi", _m), do: {:ok, "[FILTERED]"}
  defp filter_module(:"Elixir.Nerves.NetworkInterface", _m), do: nil
  defp filter_module(:"Elixir.Nerves.InterimWiFi.WiFiManager.EventHandler", _m), do: nil
  defp filter_module(:"Elixir.Nerves.InterimWiFi.DHCPManager", _), do: nil
  defp filter_module(:"Elixir.Nerves.NetworkInterface.Worker", _), do: nil
  defp filter_module(:"Elixir.Nerves.InterimWiFi.DHCPManager.EventHandler", _), do: nil
  defp filter_module(_, message), do: {:ok, message}

  defp filter_text(message) when is_list(message), do: nil
  defp filter_text(m), do: {:ok, m}

  # Couuld probably do this inline but wheres the fun in that. its a functional
  # language isn't it?
  # Takes Loggers time stamp and converts it into a unix timestamp.
  defp parse_created_at({{year, month, day}, {hour, minute, second, _}}) do
    dt = Timex.to_datetime({{year, month, day}, {hour, minute, second}})
    f = DateTime.to_iso8601(dt)
    {:ok, f}
  end
  defp parse_created_at({_,_}), do: {:ok, :os.system_time}
  defp parse_created_at(_), do: nil

  @spec build_log(String.t, number, rpc_log_type, [channels], [integer])
  :: {:ok, log_message}
  defp build_log(message, created_at, type, channels, [x,y,z]) do
    a =
      %{message: message,
        created_at: created_at,
        channels: channels,
        meta: %{
          type: type,
          x: x,
          y: y,
          z: z}}
    {:ok, a}
  end

  @type posting? :: boolean
  @spec build_state :: state
  defp build_state, do: {[], false}
end
