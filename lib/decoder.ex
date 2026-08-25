defmodule Membrane.GPUVideo.Decoder do
  @moduledoc """
  Decoder of H.264 stream taking advantage of hardware acceleration provided
  by Vulkan video extensions.
  """
  use Membrane.Filter

  alias Membrane.GPUVideo.{DeviceServer, Native}

  def_input_pad :input, accepted_format: %Membrane.H264{stream_structure: :annexb, alignment: :au}
  def_output_pad :output, accepted_format: %Membrane.RawVideo{pixel_format: :NV12}

  @impl true
  def handle_init(_ctx, _opts) do
    state = %{decoder: nil, width: nil, height: nil}
    {[], state}
  end

  @impl true
  def handle_setup(_ctx, state) do
    device = DeviceServer.get_device()
    decoder = Native.new_decoder(device)
    state = %{state | decoder: decoder}
    {[], state}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    decoded_frames = Native.decode(state.decoder, buffer.payload, buffer.pts)
    Enum.flat_map_reduce(decoded_frames, state, &prepare_actions(&1, &2))
  end

  defp prepare_actions(frame, state) do
    {maybe_stream_format_actions, state} =
      if frame.width != state.width and frame.height != state.height do
        actions = [
          stream_format:
            {:output,
             %Membrane.RawVideo{
               height: frame.height,
               width: frame.width,
               pixel_format: :NV12,
               framerate: nil,
               aligned: true
             }}
        ]

        state = %{state | width: frame.width, height: frame.height}
        {actions, state}
      else
        {[], state}
      end

    buffer_actions = [
      buffer:
        {:output,
         %Membrane.Buffer{
           payload: frame.payload,
           pts: Membrane.Time.nanoseconds(frame.pts_ns),
           dts: Membrane.Time.nanoseconds(frame.pts_ns)
         }}
    ]

    {maybe_stream_format_actions ++ buffer_actions, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    flushed_frames = Native.flush_decoder(state.decoder)
    :ok = Native.destroy(state.decoder)
    {actions, state} = Enum.flat_map_reduce(flushed_frames, state, &prepare_actions(&1, &2))
    {actions ++ [end_of_stream: :output], %{state | decoder: nil}}
  end
end
