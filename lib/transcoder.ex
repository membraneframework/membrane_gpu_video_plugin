defmodule Membrane.GPUVideo.Transcoder do
  @moduledoc """
  H.264 hardware transcoder using Vulkan Video extensions.

  Accepts a single H.264 input stream and produces multiple independently
  configured H.264 output streams. Each output pad is configured via pad options
  passed through `via_out/2`.

  > #### Pad linking requirement {: .warning}
  >
  > All output pads **must** be linked in the **same spec** in which the transcoder
  > element itself is created. Linking pads in a later spec is not supported.

  ## Example

      spec = [
        child(:source, source)
        |> child(:parser, %Membrane.H264.Parser{...})
        |> child(:transcoder, Membrane.GPUVideo.Transcoder),
        get_child(:transcoder)
        |> via_out(Pad.ref(:output, 0), options: [width: 1280, height: 720])
        |> child(:sink_hd, sink_hd),
        get_child(:transcoder)
        |> via_out(Pad.ref(:output, 1), options: [width: 640, height: 360])
        |> child(:sink_sd, sink_sd)
      ]
  """

  use Membrane.Filter
  alias Membrane.GPUVideo.{DeviceServer, Native, Transcoder.OutputSpec}

  def_options approx_framerate: [
                spec: {non_neg_integer(), pos_integer()} | nil,
                default: nil,
                description: """
                Framerate of the input stream expressed as `{numerator, denominator}`.
                It's only used by the rate control mechanism and therefore does not need to be an exact
                value. If nil, the framerate will be read from the stream format's structure or set
                to a fixed value of 30 frames per second if framerate is not provided by the stream format.
                """
              ]

  def_input_pad :input, accepted_format: %Membrane.H264{stream_structure: :annexb, alignment: :au}

  def_output_pad :output,
    availability: :on_request,
    accepted_format: %Membrane.H264{stream_structure: :annexb, alignment: :au},
    options: [
      width: [
        spec: non_neg_integer(),
        description: "Output frame width in pixels."
      ],
      height: [
        spec: non_neg_integer(),
        description: "Output frame height in pixels."
      ],
      tune: [
        spec: :low_latency | :high_quality,
        default: :low_latency,
        description: """
        Specifies whether the encoder should be optimized for minimal latency (which is
        important in case of livestreams) or for higher quality (applicable to offline encoding).
        """
      ],
      rate_control: [
        spec:
          :encoder_default
          | :disabled
          | {:variable_bitrate, Membrane.GPUVideo.Encoder.VariableBitrate.t()}
          | {:constant_bitrate, Membrane.GPUVideo.Encoder.ConstantBitrate.t()},
        default: :encoder_default,
        description: """
        Rate control mode for the output stream. See `Membrane.GPUVideo.Encoder` for
        available options.
        """
      ],
      scaling_algorithm: [
        spec: :nearest_neighbor | :lanczos3 | :bilinear,
        default: :bilinear,
        description: "Algorithm used when scaling the input to the output resolution."
      ]
    ]

  @default_framerate {30, 1}

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      transcoder: nil,
      output_specs: [],
      device: nil,
      approx_framerate_option: opts.approx_framerate,
      approx_framerate: nil
    }

    {[], state}
  end

  @impl true
  def handle_setup(_ctx, state) do
    device = DeviceServer.get_device()
    {[], %{state | device: device}}
  end

  @impl true
  def handle_pad_added(pad_ref, %{playback: :playing} = _ctx, _state) do
    raise """
    Output pad #{inspect(pad_ref)} was linked while the element is already playing. \
    All output pads must be linked in the same spec as the transcoder element.
    """
  end

  @impl true
  def handle_pad_added(pad_ref, ctx, state) do
    pad_opts = ctx.pads[pad_ref].options

    spec = %OutputSpec{
      width: pad_opts.width,
      height: pad_opts.height,
      tune: pad_opts.tune,
      rate_control: pad_opts.rate_control,
      scaling_algorithm: pad_opts.scaling_algorithm
    }

    {[], %{state | output_specs: [{pad_ref, spec} | state.output_specs]}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    new_framerate =
      if is_nil(state.approx_framerate_option) do
        stream_format.framerate || @default_framerate
      else
        state.approx_framerate_option
      end

    old_framerate = state.approx_framerate

    state = %{state | approx_framerate: new_framerate}

    if is_nil(state.transcoder) or new_framerate != old_framerate do
      spawn_transcoder(state)
    else
      {[], state}
    end
  end

  defp spawn_transcoder(state) do
    specs = state.output_specs |> Enum.map(fn {_pad_ref, spec} -> spec end)
    transcoder = Native.new_transcoder(state.device, specs, state.approx_framerate)
    state = %{state | transcoder: transcoder}

    stream_format_actions =
      state.output_specs
      |> Enum.map(fn {pad_ref, spec} ->
        stream_format = %Membrane.H264{
          stream_structure: :annexb,
          alignment: :au,
          width: spec.width,
          height: spec.height,
          framerate: state.approx_framerate
        }

        {:stream_format, {pad_ref, stream_format}}
      end)

    {stream_format_actions, state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    actions =
      Native.transcode(state.transcoder, buffer.payload, buffer.pts)
      |> build_buffer_actions(state)

    {actions, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    buffer_actions = Native.flush_transcoder(state.transcoder) |> build_buffer_actions(state)

    eos_actions =
      state.output_specs |> Enum.map(fn {pad_ref, _spec} -> {:end_of_stream, pad_ref} end)

    {buffer_actions ++ eos_actions, %{state | transcoder: nil}}
  end

  defp build_buffer_actions(frames_per_pads, state) do
    Enum.flat_map(frames_per_pads, fn frame_per_pads ->
      Enum.zip(frame_per_pads, state.output_specs)
      |> Enum.map(fn {frame, {pad_ref, _spec}} ->
        pts = if frame.pts_ns != nil, do: Membrane.Time.nanoseconds(frame.pts_ns), else: nil
        {:buffer, {pad_ref, %Membrane.Buffer{payload: frame.payload, pts: pts}}}
      end)
    end)
  end
end
