defmodule Gas.Tags.CaseTag do
  @moduledoc """
  case tag
  """
  alias Gas.{Argument, Parser}

  @type t :: %__MODULE__{
          loc: Parser.Loc.t(),
          argument: Argument.t(),
          cases: [{[Argument.t()] | :else, [Parser.entry()]}]
        }

  @enforce_keys [:loc, :argument, :cases]
  defstruct [:loc, :argument, :cases]

  @behaviour Gas.Tag

  @impl true
  def parse("case", loc, context) do
    with {:ok, tokens, context} <- Gas.Lexer.tokenize_tag_end(context),
         {:ok, argument, [{:end, _}]} <- Argument.parse(tokens),
         {:ok, cases, context} <- parse_cases(context) do
      {:ok, %__MODULE__{loc: loc, argument: argument, cases: cases}, context}
    else
      {:ok, _argument, rest} -> {:error, "Unexpected token", Parser.meta_head(rest)}
      {:error, reason, _rest, loc} -> {:error, reason, loc}
      error -> error
    end
  end

  defp parse_cases(context) do
    # We just want to parse whatever is after {% case %} and before the first when, else or endcase
    with {:ok, _, tag_name, tokens, context} <-
           Parser.parse_until(context, ~w(when else endcase), "Expected endcase") do
      do_parse_cases(tag_name, tokens, context, [])
    end
  end

  defp do_parse_cases("when", tokens, context, acc) do
    with {:ok, arguments} <- parse_arguments(tokens),
         {:ok, result, tag_name, tokens, context} <-
           Parser.parse_until(context, ~w(when else endcase), "Expected endcase") do
      do_parse_cases(tag_name, tokens, context, [
        {arguments, Parser.remove_blank_text_if_blank_body(result)} | acc
      ])
    end
  end

  defp do_parse_cases("else", tokens, context, acc) do
    with {:tokens, [{:end, _}]} <- {:tokens, tokens},
         {:ok, result, tag_name, tokens, context} <-
           Parser.parse_until(context, ~w(when else endcase), "Expected endcase") do
      do_parse_cases(tag_name, tokens, context, [
        {:else, Parser.remove_blank_text_if_blank_body(result)} | acc
      ])
    else
      {:tokens, tokens} ->
        {:error, "Unexpected token on else", Parser.meta_head(tokens)}

      error ->
        error
    end
  end

  defp do_parse_cases("endcase", tokens, context, acc) do
    case tokens do
      [{:end, _}] -> {:ok, Enum.reverse(acc), context}
      _ -> {:error, "Unexpected token on endcase", Parser.meta_head(tokens)}
    end
  end

  defp parse_arguments(tokens, acc \\ []) do
    with {:ok, argument, tokens} <- Argument.parse(tokens) do
      case tokens do
        [{:comma, _} | tokens] -> parse_arguments(tokens, [argument | acc])
        [{:identifier, _, "or"} | tokens] -> parse_arguments(tokens, [argument | acc])
        [{:end, _}] -> {:ok, Enum.reverse([argument | acc])}
        _ -> {:error, "Expected ',' or 'or'", Parser.meta_head(tokens)}
      end
    end
  end

  defimpl Gas.Renderable do
    alias Gas.BinaryCondition

    def render(tag, context, options) do
      {:ok, value, context} = Gas.Argument.get(tag.argument, context, [], options)

      {chosen_body, context} =
        Enum.reduce_while(tag.cases, {nil, context}, fn case_clause, {else_body, ctx} ->
          eval_case(case_clause, value, else_body, ctx, options)
        end)

      {List.wrap(chosen_body), context}
    end

    # handle else clause
    defp eval_case({:else, body}, _value, _else_body, ctx, _options) do
      # record else as fallback, but keep scanning in case a match appears later
      {:cont, {body, ctx}}
    end

    # handle case with arguments
    defp eval_case({arguments, body}, value, else_body, ctx, options) do
      case match_arguments(arguments, value, ctx, options) do
        {:match, ctx2} -> {:halt, {body, ctx2}}
        {:no_match, ctx2} -> {:cont, {else_body, ctx2}}
      end
    end

    defp match_arguments(arguments, value, context, options) do
      Enum.reduce_while(arguments, {:no_match, context}, fn arg, {_, ctx} ->
        {:ok, arg_value, ctx2} = Gas.Argument.get(arg, ctx, [], options)

        if BinaryCondition.eval({value, :==, arg_value}) == {:ok, true} do
          {:halt, {:match, ctx2}}
        else
          {:cont, {:no_match, ctx2}}
        end
      end)
    end
  end
end
