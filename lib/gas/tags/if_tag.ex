defmodule Gas.Tags.IfTag do
  @moduledoc """
  Handle if and unless tags
  """
  @behaviour Gas.Tag

  alias Gas.{ConditionExpression, Parser.Loc, Parser}

  @enforce_keys [:loc, :tag_name, :body, :elsifs, :else_body, :condition]
  defstruct [:loc, :tag_name, :body, :elsifs, :else_body, :condition]

  @type t :: %__MODULE__{
          loc: Loc.t(),
          tag_name: :if | :unless,
          elsifs: [{ConditionExpression.condition(), [Parser.entry()]}],
          body: [Parser.entry()],
          else_body: [Parser.entry()],
          condition: ConditionExpression.condition()
        }

  defp ignore_until_end("if", "endif", context), do: {:ok, context}
  defp ignore_until_end("unless", "endunless", context), do: {:ok, context}

  defp ignore_until_end(starting_tag_name, _tag_name, context) do
    tags = if starting_tag_name == "if", do: "endif", else: "endunless"

    case Parser.parse_until(context, tags, "Expected endif") do
      {:ok, _result, _tag_name, _tokens, context} ->
        {:ok, context}

      {:error, "Expected 'endif'", meta} ->
        {:error, "Expected '#{tags}'", meta}

      {:error, reason, meta} ->
        {:error, "Expected '#{tags}'. Got: #{reason}", meta}
    end
  end

  @impl true
  def parse(starting_tag_name, loc, context) when starting_tag_name in ["if", "unless"] do
    with {:ok, tokens, context} <- Gas.Lexer.tokenize_tag_end(context),
         {:ok, condition} <- ConditionExpression.parse(tokens),
         {:ok, body, tag_name, tokens, context} <- parse_body(starting_tag_name, context),
         {:ok, elsifs, tag_name, context} <-
           parse_elsifs(starting_tag_name, tag_name, tokens, context),
         {:ok, else_body, tag_name, context} <-
           parse_else_body(starting_tag_name, tag_name, context),
         # Here we ignore until and endif or endunless is found ignoring extra
         # elses and elsifs
         {:ok, context} <- ignore_until_end(starting_tag_name, tag_name, context) do
      {:ok,
       %__MODULE__{
         tag_name: String.to_existing_atom(starting_tag_name),
         body: Parser.remove_blank_text_if_blank_body(body),
         else_body: Parser.remove_blank_text_if_blank_body(else_body),
         elsifs: elsifs,
         condition: condition,
         loc: loc
       }, context}
    end
  end

  defp parse_body(starting_tag_name, context) do
    tags = if starting_tag_name == "if", do: ~w(elsif else endif), else: ~w(elsif else endunless)
    expected_end_tag = if starting_tag_name == "if", do: "endif", else: "endunless"

    case Parser.parse_until(context, tags, "Expected 'endif'") do
      {:ok, result, tag_name, tokens, context} ->
        {:ok, result, tag_name, tokens, context}

      {:error, "Expected 'endif'", meta} ->
        {:error, "Expected '#{expected_end_tag}'", meta}

      {:error, reason, meta} ->
        {:error, "Expected one of '#{Enum.join(tags, "', '")}' tags. Got: #{reason}", meta}
    end
  end

  defp parse_elsifs(starting_tag_name, tag_name, tokens, context, acc \\ [])

  defp parse_elsifs("if", "endif", _tokens, context, acc),
    do: {:ok, Enum.reverse(acc), "endif", context}

  defp parse_elsifs("unless", "endunless", _tokens, context, acc),
    do: {:ok, Enum.reverse(acc), "endunless", context}

  defp parse_elsifs(_starting_tag_name, "else", _tokens, context, acc),
    do: {:ok, Enum.reverse(acc), "else", context}

  defp parse_elsifs(starting_tag_name, "elsif", tokens, context, acc) do
    tags = if starting_tag_name == "if", do: ~w(else endif), else: ~w(else endunless)

    case Parser.maybe_tokenize_tag(tags, context) do
      {:tag, tag_name, _tokens, context} ->
        {:ok, Enum.reverse(acc), tag_name, context}

      _ ->
        with {:ok, condition} <- ConditionExpression.parse(tokens),
             {:ok, body, tag_name, tokens, context} <- parse_body(starting_tag_name, context) do
          parse_elsifs(starting_tag_name, tag_name, tokens, context, [
            {condition, Parser.remove_blank_text_if_blank_body(body)} | acc
          ])
        end
    end
  end

  defp parse_else_body("if", "endif", context), do: {:ok, [], "endif", context}
  defp parse_else_body("unless", "endunless", context), do: {:ok, [], "endunless", context}

  defp parse_else_body(starting_tag_name, "else", context) do
    tag = if starting_tag_name == "if", do: ~w(endif else elsif), else: ~w(endunless else elsif)
    expected_tag = if starting_tag_name == "if", do: "endif", else: "endunless"

    case Parser.parse_until(context, tag, "Expected 'endif'") do
      {:ok, result, tag_name, _tokens, context} ->
        {:ok, result, tag_name, context}

      {:error, "Expected 'endif'", meta} ->
        {:error, "Expected '#{expected_tag}'", meta}

      {:error, reason, meta} ->
        {:error, "Expected '#{expected_tag}' tag. Got: #{reason}", meta}
    end
  end

  defimpl Gas.Renderable do
    alias Gas.Tags.IfTag

    # handle :if
    def render(
          %IfTag{
            tag_name: :if,
            condition: condition,
            body: body,
            elsifs: elsifs,
            else_body: else_body
          },
          context,
          options
        ) do
      case ConditionExpression.eval(condition, context, options) do
        {:ok, true, context} ->
          {body, context}

        {:ok, false, context} ->
          eval_elsifs(elsifs, else_body, context, options)

        {:error, exception, context} ->
          return_error(exception, context)
      end
    end

    # handle :unless
    def render(
          %IfTag{
            tag_name: :unless,
            condition: condition,
            body: body,
            elsifs: elsifs,
            else_body: else_body
          },
          context,
          options
        ) do
      case ConditionExpression.eval(condition, context, options) do
        {:ok, false, context} ->
          {body, context}

        {:ok, true, context} ->
          eval_elsifs(elsifs, else_body, context, options)

        {:error, exception, context} ->
          return_error(exception, context)
      end
    end

    # evaluate elsifs and else
    defp eval_elsifs(elsifs, else_body, context, options) do
      Enum.reduce_while(elsifs, :continue, fn {condition, body}, _acc ->
        case ConditionExpression.eval(condition, context, options) do
          {:ok, true, context} -> {:halt, {:ok, body, context}}
          {:ok, false, _context} -> {:cont, :continue}
          {:error, exception, context} -> {return_error(exception, context)}
        end
      end)
      |> case do
        {:ok, result, context} -> {result, context}
        {:error, message, context} -> {message, context}
        :continue -> {else_body || [], context}
      end
    end

    defp return_error(exception, context) do
      context = Gas.Context.put_errors(context, exception)
      {Exception.message(exception), context}
    end
  end
end
