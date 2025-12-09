defmodule Gas.Tags.AssignTag do
  @moduledoc """
  assign tag
  """
  alias Gas.{Argument, Parser, Object}

  @type t :: %__MODULE__{
          loc: Parser.Loc.t(),
          argument: Argument.t(),
          object: Object.t()
        }

  @enforce_keys [:loc, :argument, :object]
  defstruct [:loc, :argument, :object]

  @behaviour Gas.Tag

  @impl true
  def parse("assign", loc, context) do
    with {:ok, tokens, context} <- Gas.Lexer.tokenize_tag_end(context),
         {:ok, argument, tokens} <- Argument.parse(tokens),
         [{:assignment, _} | tokens] <- tokens,
         {:ok, object, [{:end, _}]} <- Gas.Object.parse(tokens) do
      {:ok, %__MODULE__{loc: loc, argument: argument, object: object}, context}
    else
      {:error, reason, _rest, loc} -> {:error, reason, loc}
      error -> error
    end
  end

  defimpl Gas.Renderable do
    def render(tag, context, options) do
      {:ok, new_value, context} =
        Gas.Argument.get(tag.object.argument, context, tag.object.filters, options)

      context = %{context | vars: Map.put(context.vars, to_string(tag.argument), new_value)}

      {[], context}
    end
  end

  defimpl Gas.Block do
    def blank?(_), do: true
  end
end
