defmodule Membrane.GPUVideo.Encoder do
  @moduledoc """
  H.264 encoder taking advantage of hardware acceleration provided
  by Vulkan video extensions.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.GPUVideo.{DeviceServer, Native}

  def_input_pad :input, accepted_format: %Membrane.RawVideo{pixel_format: :NV12}

  def_output_pad :output,
    accepted_format: %Membrane.H264{stream_structure: :annexb, alignment: :au}

  def_options tune: [
                spec: :low_latency | :high_quality,
                default: :low_latency,
                description: """
                Specifies whether the encoder should be optimized for minimal latency (which is
                important in case of livestreams) or for higher quality (applicable to offline encoding).
                """
              ],
              approx_framerate: [
                spec: {non_neg_integer(), pos_integer()} | nil,
                default: nil,
                description: """
                Framerate of the stream expressed in number of frames per second.
                It's only used by the rate control mechanism and therefore it does not need to be an exact
                value. If nil, the framerate will be read from the stream format's structure or set
                to fixed value of 30 frames per second if framerate is not provided by the stream format.
                """
              ],
              rate_control: [
                spec:
                  :encoder_default
                  | :disabled
                  | {:variable_bitrate, __MODULE__.VariableBitrate.t()}
                  | {:constant_bitrate, __MODULE__.ConstantBitrate.t()},
                default: :encoder_default,
                description: """
                Specifies which rate control mechanism should by used by the encoder.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      encoder: nil,
      width: nil,
      height: nil,
      override_framerate?: opts.approx_framerate != nil,
      approx_framerate: opts.approx_framerate,
      rate_control: opts.rate_control,
      tune: opts.tune
    }

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    cond do
      state.override_framerate? and
          (stream_format.width != state.width or
             stream_format.height != state.height) ->
        %{
          state
          | width: stream_format.width,
            height: stream_format.height
        }
        |> spawn_encoder()

      not state.override_framerate? and
          (stream_format.width != state.width or stream_format.height != state.height or
             stream_format.framerate != state.approx_framerate) ->
        %{
          state
          | width: stream_format.width,
            height: stream_format.height,
            approx_framerate: resolve_framerate(stream_format, state)
        }
        |> spawn_encoder()

      true ->
        {[], state}
    end
  end

  defp spawn_encoder(state) do
    device = DeviceServer.get_device()

    encoder =
      Native.new_encoder(
        device,
        state.width,
        state.height,
        state.approx_framerate,
        state.tune,
        state.rate_control
      )

    state = put_in(state, [:encoder], encoder)

    stream_format =
      %Membrane.H264{
        stream_structure: :annexb,
        alignment: :au,
        width: state.width,
        height: state.height
      }

    stream_format =
      if state.override_framerate? do
        stream_format
      else
        %{stream_format | framerate: state.approx_framerate}
      end

    {[stream_format: {:output, stream_format}], state}
  end

  defp resolve_framerate(stream_format, state) do
    if is_nil(stream_format.framerate) and requires_framerate?(state.rate_control) do
      Membrane.Logger.warning("""
          Framerate is required when using #{inspect(elem(state.rate_control, 0))} rate control but it
          wasn't provided in the stream format nor via options. Please provide approximate framerate
          using `approx_framerate` option of the element.
      """)
    end

    stream_format.framerate || {30, 1}
  end

  defp requires_framerate?({:constant_bitrate, _constant_bitrate}), do: true
  defp requires_framerate?({:variable_bitrate, _variable_bitrate}), do: true
  defp requires_framerate?(_other_rate_control), do: false

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    encoded_frame = Native.encode(state.encoder, buffer.payload, buffer.pts)

    pts =
      if encoded_frame.pts_ns != nil,
        do: Membrane.Time.nanoseconds(encoded_frame.pts_ns),
        else: nil

    {[
       buffer:
         {:output,
          %Membrane.Buffer{
            payload: encoded_frame.payload,
            pts: pts,
            dts: buffer.dts
          }}
     ], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    :ok = Native.destroy(state.encoder)
    state = %{state | encoder: nil}
    {[end_of_stream: :output], state}
  end
end
