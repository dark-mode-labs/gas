# credo:disable-for-this-file
defmodule Gas.Tags.NoOpTag do
  @enforce_keys [:loc]
  defstruct [:loc]

  @behaviour Gas.Tag

  @impl true
  def parse(tag, loc, context) do
    with {:ok, _tokens, context} <- Gas.Lexer.tokenize_tag_end(context),
         {:ok, context} <- ignore_body("end#{tag}", context) do
      {:ok, %__MODULE__{loc: loc}, context}
    end
  end

  @whitespaces [" ", "\f", "\r", "\t", "\v"]

  defp ignore_body(endtag, context) do
    case context.rest do
      <<"\n", rest::binary>> ->
        if context.mode == :liquid_tag do
          case Gas.Parser.maybe_tokenize_tag(endtag, context) do
            {:tag, _tag_name, _tokens, context} ->
              {:ok, context}

            {:not_found, context} ->
              ignore_body(endtag, %{context | rest: rest, line: context.line + 1, column: 1})
          end
        else
          ignore_body(endtag, %{context | rest: rest, line: context.line + 1, column: 1})
        end

      <<c::binary-size(1), rest::binary>> when c in @whitespaces ->
        ignore_body(endtag, %{context | rest: rest, column: context.column + 1})

      <<"{%", rest::binary>> ->
        case Gas.Parser.maybe_tokenize_tag(endtag, context) do
          {:tag, _tag_name, _tokens, context} ->
            {:ok, context}

          {:not_found, context} ->
            ignore_body(endtag, %{context | rest: rest, column: context.column + 2})
        end

      "" ->
        "end" <> tag = endtag
        {:error, "#{tag} tag not terminated", %{line: context.line, column: context.column}}

      ^endtag <> _ ->
        if context.mode == :liquid_tag do
          {:tag, _, _, context} = Gas.Parser.maybe_tokenize_tag(endtag, context)
          {:ok, context}
        else
          <<_c, rest::binary>> = context.rest

          ignore_body(endtag, %{
            context
            | rest: rest,
              line: context.line,
              column: context.column + 1
          })
        end

      <<_c, rest::binary>> ->
        ignore_body(endtag, %{context | rest: rest, column: context.column + 1})
    end
  end

  defimpl Gas.Renderable do
    def render(_tag, context, _options) do
      {[], context}
    end
  end

  defimpl Gas.Block do
    def blank?(_), do: true
  end
end
