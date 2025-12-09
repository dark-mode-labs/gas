defmodule Gas.Tags.RenderTag do
  alias Gas.{Argument, Context, Parser}
  alias Gas.Parser.Loc

  @type t :: %__MODULE__{
          loc: Loc.t(),
          template: binary,
          arguments:
            {:with, {source :: Argument.t(), destination :: binary}}
            | {:for, {source :: Argument.t(), destination :: binary}}
            | %{binary => Argument.t()}
        }

  @enforce_keys [:loc, :template, :arguments]
  defstruct [:loc, :template, :arguments]

  @behaviour Gas.Tag

  @impl true
  def parse("render", loc, context) do
    with {:ok, tokens, context} <- Gas.Lexer.tokenize_tag_end(context),
         {:ok, template, tokens} <- template(tokens),
         {:ok, arguments} <- parse_arguments(tokens, template) do
      {:ok, %__MODULE__{loc: loc, template: template, arguments: arguments}, context}
    end
  end

  defp parse_arguments(tokens, template) do
    case tokens do
      [{:identifier, _, "with"} | rest] -> parse_with_or_for_arguments(rest, :with, template)
      [{:identifier, _, "for"} | rest] -> parse_with_or_for_arguments(rest, :for, template)
      # Parse optional comma
      [{:comma, _} | rest] -> parse_list_of_arguments(rest)
      # No initial comma
      [{:identifier, _, _} | _] -> parse_list_of_arguments(tokens)
      [{:end, _}] -> {:ok, %{}}
      _ -> {:error, "Expected arguments, 'with' or 'for'", Parser.meta_head(tokens)}
    end
  end

  defp parse_with_or_for_arguments(tokens, type, template) do
    with {:ok, first, tokens} <- Argument.parse(tokens) do
      case tokens do
        [{:identifier, _, "as"}, {:identifier, _, key}, {:end, _}] ->
          {:ok, {type, {first, key}}}

        [{:end, _}] ->
          {:ok, {type, {first, template}}}

        _ ->
          {:error, "Unexpected token", Parser.meta_head(tokens)}
      end
    end
  end

  defp parse_list_of_arguments(tokens, acc \\ %{}) do
    case tokens do
      [{:identifier, loc, _key} = first, {:dot, _} = dot | rest] ->
        {identifier_collectors, others} =
          Enum.split_while(rest, fn
            {:identifier, _, _} -> true
            {:dot, _} -> true
            _ -> false
          end)

        if Enum.any?(identifier_collectors, fn
             {:identifier, _, _key} -> false
             {:dot, _} -> false
             _ -> true
           end) do
          {:error, "Expected dotted identifier to have a colon assignment",
           Gas.Parser.meta_head(rest)}
        else
          key =
            Enum.map_join([first, dot | identifier_collectors], "", fn
              {:identifier, _, key} -> key
              {:dot, _} -> "."
            end)

          parse_list_of_arguments(
            [{:identifier, loc, key} | others],
            acc
          )
        end

      [{:identifier, _, key}, {:colon, _} | rest] ->
        with {:ok, value, rest} <- Argument.parse(rest) do
          acc = Map.put(acc, key, value)

          case rest do
            [{:comma, _} | rest] ->
              parse_list_of_arguments(rest, acc)

            [{:end, _}] ->
              {:ok, acc}

            _ ->
              {:error, "Expected arguments, 'with' or 'for'", Gas.Parser.meta_head(rest)}
          end
        end

      _ ->
        {:error, "Expected arguments, 'with' or 'for'", Gas.Parser.meta_head(tokens)}
    end
  end

  defp template(tokens) do
    case tokens do
      [{:string, _meta, value, _quotes} | rest] ->
        {:ok, %Gas.Literal{value: value, loc: nil}, rest}

      [{:identifier, _meta, value} | rest] ->
        {:ok, %Gas.Variable{identifier: value, original_name: value, accesses: [], loc: nil},
         rest}

      _ ->
        {:error, "Expected template name as a quoted string", tokens}
    end
  end

  defimpl Gas.Renderable do
    def render(tag, context, options) do
      tag
      |> get_template_name(context, options)
      |> get_or_put_cache(options)
      |> do_render(tag, context, options)
    end

    defp get_template_name(tag, context, options) do
      {:ok, template_name, _context} = Argument.get(tag.template, context, [], options)

      template_name
    end

    defp get_or_put_cache(template, options) do
      Gas.precompile(
        template,
        Keyword.put_new(options, :file_system, {Gas.BlankFileSystem, nil})
      )
    end

    defp do_render({:error, %{loc: _} = exception}, tag, context, _options) do
      {[], Gas.Context.put_errors(context, [%{exception | loc: tag.loc}])}
    end

    defp do_render({:error, exception}, _tag, context, _options) do
      {[], Gas.Context.put_errors(context, [exception])}
    end

    defp do_render({:ok, []}, _tag, context, _options) do
      {[], context}
    end

    defp do_render({:ok, {_template_name, %Gas.Template{} = template}}, tag, context, options) do
      do_render({:ok, template}, tag, context, options)
    end

    defp do_render({:ok, %Gas.Template{} = template}, tag, context, options) do
      {inner_contexts, context} = build_contexts(tag.arguments, context, options)

      {rendered_text, context} =
        Enum.reduce(inner_contexts, {[], context}, fn inner_context, {result, context} ->
          case Gas.render(template, inner_context, options) do
            {:ok, rendered_text, errors} ->
              {[rendered_text | result], Gas.Context.put_errors(context, Enum.reverse(errors))}

            {:error, errors, rendered_text} ->
              {[rendered_text | result], Gas.Context.put_errors(context, Enum.reverse(errors))}
          end
        end)

      {Enum.reverse(rendered_text), context}
    end

    defp build_contexts({:with, {source, destination}}, outer_context, options) do
      {:ok, destination, _context} =
        if is_struct(destination) do
          Argument.get(destination, outer_context, [], options)
        else
          {:ok, destination, outer_context}
        end

      {:ok, value, outer_context} = Argument.get(source, outer_context, [], options)
      inner_context = %Context{vars: %{destination => value}}

      {[inner_context], outer_context}
    end

    defp build_contexts({:for, {source, destination}}, outer_context, options) do
      {:ok, destination, _context} =
        if is_struct(destination) do
          Argument.get(destination, outer_context, [], options)
        else
          {:ok, destination, outer_context}
        end

      {:ok, value, outer_context} = Argument.get(source, outer_context, [], options)

      if is_list(value) do
        length = Enum.count(value)

        inner_contexts =
          value
          |> Enum.with_index(0)
          |> Enum.map(fn {v, index} ->
            forloop = build_forloop_map(index, length)
            %Context{vars: %{destination => v}, iteration_vars: %{"forloop" => forloop}}
          end)

        {inner_contexts, outer_context}
      else
        inner_context = %Context{vars: %{destination => value}}
        {[inner_context], outer_context}
      end
    end

    defp build_contexts(args, outer_context, options) do
      {vars, outer_context} =
        Enum.reduce(args, {%{}, outer_context}, fn {k, v}, {args, outer_context} ->
          {:ok, value, outer_context} = Argument.get(v, outer_context, [], options)

          {k, v} =
            if String.contains?(k, ".") do
              build_drops_arg(k, value, outer_context, options)
            else
              {k, value}
            end

          {Map.put(args, k, v), outer_context}
        end)

      inner_context = %Context{vars: vars}
      {[inner_context], outer_context}
    end

    defp build_drops_arg(dotted_arg, value, context, options) do
      [head | rest] = String.split(dotted_arg, ".")

      map_value =
        rest
        |> Enum.reverse()
        |> Enum.reduce(value, fn key, acc ->
          %{key => acc}
        end)

      current_map_value =
        case Argument.get(
               %Gas.Variable{
                 identifier: head,
                 loc: nil,
                 accesses: [],
                 original_name: head
               },
               context,
               [],
               options
             ) do
          {:ok, %{} = value, _outer_context} ->
            value

          _ ->
            %{}
        end

      merged_value = Map.merge(current_map_value, map_value)

      {head, merged_value}
    end

    defp build_forloop_map(index, length) do
      %{
        "index" => index + 1,
        "index0" => index,
        "rindex" => length - index,
        "rindex0" => length - index - 1,
        "first" => index == 0,
        "last" => length == index + 1,
        "length" => length
      }
    end
  end
end
