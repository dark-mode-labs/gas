defmodule Solid.Preprocessor do
  @callback process(template :: binary(), options :: Keyword.t()) :: binary()
end

defmodule Solid.PassThroughPreProcessor do
  @moduledoc """
  Default file system that return error on call
  """
  @behaviour Solid.Preprocessor

  @impl true
  def process(template, _opts) do
    template
  end
end
