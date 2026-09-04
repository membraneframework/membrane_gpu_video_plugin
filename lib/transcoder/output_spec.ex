defmodule Membrane.GPUVideo.Transcoder.OutputSpec do
  @moduledoc false

  alias Membrane.GPUVideo.Encoder

  @type t :: %__MODULE__{
          width: non_neg_integer(),
          height: non_neg_integer(),
          tune: :low_latency | :high_quality,
          rate_control:
            :encoder_default
            | :disabled
            | {:variable_bitrate, Encoder.VariableBitrate.t()}
            | {:constant_bitrate, Encoder.ConstantBitrate.t()},
          scaling_algorithm: :nearest_neighbor | :lanczos3 | :bilinear
        }

  @enforce_keys [:width, :height]
  defstruct @enforce_keys ++
              [
                tune: :low_latency,
                rate_control: :encoder_default,
                scaling_algorithm: :bilinear
              ]
end
