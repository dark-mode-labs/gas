defmodule Solid.Preprocessor do
  @callback process(template_or_path :: binary(), content :: binary()) :: binary()
end

defmodule Solid.PassThroughPreProcessor do
  @moduledoc """
  Default file system that return error on call
  """
  @behaviour Solid.Preprocessor

  @impl true
  def process(template_or_path, nil) do
    template_or_path
  end

  def process(_template_or_path, content) do
    content
  end
end
