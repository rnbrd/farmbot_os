defmodule Fw do
  require Logger
  use Supervisor
  @target System.get_env("NERVES_TARGET") || "rpi3"
  @update_server Application.get_env(:fb, :update_server)
  @version Path.join(__DIR__ <> "/..", "VERSION")
    |> File.read!
    |> String.strip

  def init(_args) do
    children = [
      Plug.Adapters.Cowboy.child_spec(:http, MyRouter, [], [port: 4000]),
      supervisor(NetworkSupervisor, [[]], restart: :permanent),
      supervisor(Controller, [[]], restart: :permanent)
    ]
    opts = [strategy: :one_for_all, name: Fw]
    supervise(children, opts)
  end

  def start(_type, args) do
    Logger.debug("Starting Firmware on Target: #{@target}")
    Supervisor.start_link(__MODULE__, args)
  end

  def version do
    @version
  end

  def factory_reset do
    File.rm("/root/secretes.txt")
    File.rm("/root/network.config")
    Nerves.Firmware.reboot
  end

  def check_updates(url \\ @update_server) do
    resp = HTTPotion.get url,
    [headers: ["User-Agent": "Farmbot"]]
    current_version = Fw.version
    case resp do
      %HTTPotion.ErrorResponse{message: error} ->
        {:error, "Check Updates failed", error}
      _ ->
        json = Poison.decode!(resp.body)
        "v"<>new_version = Map.get(json, "tag_name")
        new_version_url = Map.get(json, "assets")
        |> Enum.find(fn asset ->
                     String.contains?(Map.get(asset, "browser_download_url"),
                                              ".fw") end)
        |> Map.get("browser_download_url")
        case (new_version != current_version) do
          true -> {:update, new_version_url}
          _ -> :no_updates
        end
    end
  end

  def get_url do
    @update_server
  end
end