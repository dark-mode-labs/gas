defmodule Gas.Preprocessor do
  @moduledoc false

  @callback process(template_or_path :: binary(), content :: binary()) :: binary()
end

defmodule Gas.PassThroughPreProcessor do
  @moduledoc """
  Default file system that return error on call
  """
  @behaviour Gas.Preprocessor

  @impl true
  def process(template_or_path, nil) do
    template_or_path
  end

  def process(_template_or_path, content) do
    content
  end
end
