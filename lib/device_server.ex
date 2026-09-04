defmodule Membrane.GPUVideo.DeviceServer do
  @moduledoc false
  use GenServer
  alias Membrane.GPUVideo.Native

  @impl true
  def init(_opts) do
    {:ok, %{device: nil}}
  end

  @impl true
  def handle_call(:get_device, _from, state) do
    state = maybe_create_device(state)
    {:reply, state.device, state}
  end

  defp maybe_create_device(%{device: nil} = state) do
    device = Native.create_device()
    %{state | device: device}
  end

  defp maybe_create_device(state), do: state

  @spec get_device() :: Native.t() | no_return()
  def get_device() do
    GenServer.call(__MODULE__, :get_device)
  end
end
