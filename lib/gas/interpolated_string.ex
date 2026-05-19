defmodule Gas.InterpolatedString do
  @moduledoc """
  Wraps a binary that contained Liquid syntax when it entered a
  `Gas.Context`. The pre-parsed `%Gas.Template{}` is rendered in place
  of the binary at variable resolution time.
  """

  @enforce_keys [:ast, :original]
  defstruct [:ast, :original]

  @type t :: %__MODULE__{ast: Gas.Template.t(), original: binary}
end
