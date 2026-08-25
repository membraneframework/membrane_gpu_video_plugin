defmodule Membrane.GPUVideo.Native do
  @moduledoc false
  use Rustler, otp_app: :membrane_gpu_video_plugin, crate: :gpuvideo

  @type t :: reference()
  @type raw_frame :: %{
          payload: binary(),
          pts: non_neg_integer() | nil,
          width: non_neg_integer(),
          height: non_neg_integer()
        }

  @type encoded_frame :: %{
          payload: binary(),
          pts: non_neg_integer() | nil
        }

  @spec create_device() :: t() | no_return()
  def create_device(), do: :erlang.nif_error(:nif_not_loaded)

  @spec new_decoder(t()) :: t() | no_return()
  def new_decoder(_device), do: :erlang.nif_error(:nif_not_loaded)

  @spec decode(t(), binary(), pts_ns :: non_neg_integer() | nil) ::
          [raw_frame()] | no_return()
  def decode(_decoder, _frame, _pts \\ nil), do: :erlang.nif_error(:nif_not_loaded)

  @spec flush_decoder(t()) ::
          [raw_frame()] | no_return()
  def flush_decoder(_decoder), do: :erlang.nif_error(:nif_not_loaded)

  @spec new_encoder(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()},
          :low_latency | :high_quality,
          :encoder_default
          | :disabled
          | {:variable_bitrate, Membrane.GPUVideo.Encoder.VariableBitrate.t()}
          | {:constant_bitrate, Membrane.GPUVideo.Encoder.ConstantBitrate.t()}
        ) :: t() | no_return()
  def new_encoder(_device, _width, _height, _framerate, _tune, _rate_control),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec encode(t(), binary(), pts_ns :: non_neg_integer() | nil) ::
          encoded_frame() | no_return()
  def encode(_encoder, _raw_frame, _pts_ns \\ nil), do: :erlang.nif_error(:nif_not_loaded)

  @spec destroy(t()) :: :ok
  def destroy(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @spec new_transcoder(
          t(),
          [Membrane.GPUVideo.Transcoder.OutputSpec.t()],
          {non_neg_integer(), pos_integer()}
        ) ::
          t() | no_return()
  def new_transcoder(_device, _output_specs, _approx_framerate),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec transcode(t(), binary(), non_neg_integer() | nil) ::
          [[encoded_frame()]] | no_return()
  def transcode(_transcoder, _payload, _pts_ns \\ nil), do: :erlang.nif_error(:nif_not_loaded)

  @spec flush_transcoder(t()) :: [[encoded_frame()]] | no_return()
  def flush_transcoder(_transcoder), do: :erlang.nif_error(:nif_not_loaded)
end
