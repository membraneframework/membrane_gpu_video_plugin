defmodule Membrane.GPUVideo do
  @moduledoc false
  use Application

  alias Membrane.GPUVideo.DeviceServer

  @impl true
  def start(_start_type, _start_args) do
    GenServer.start_link(DeviceServer, nil, name: DeviceServer)
  end
end
