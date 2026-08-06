defmodule Gas.Filters.Filter.Utils do
  @moduledoc "Shared helpers for all filters"
  alias Gas.Literal.Empty

  @zero Decimal.new(0)

  # Type coercion
  def to_str(nil), do: ""
  def to_str(%Empty{}), do: ""

  def to_str(input) when is_float(input) do
    Decimal.from_float(input) |> Decimal.to_string(:xsd)
  end

  def to_str(input), do: to_string(input)

  def to_enum(input) when is_list(input), do: List.flatten(input)
  def to_enum(%Range{} = r), do: Enum.to_list(r)
  def to_enum(tuple) when is_tuple(tuple), do: Tuple.to_list(tuple)
  def to_enum(other), do: [other]

  # Numbers
  def to_integer!(input) when is_integer(input), do: input

  def to_integer!(input) when is_binary(input) do
    String.to_integer(input)
  end

  def to_integer!(_), do: raise(%Gas.ArgumentError{message: "invalid integer"})

  def to_integer(input) when is_integer(input), do: input
  def to_integer(input) when is_float(input), do: Kernel.round(input)

  def to_integer(input) when is_binary(input) do
    case Integer.parse(input) do
      {i, _} -> i
      _ -> 0
    end
  end

  def to_integer(_), do: 0

  def to_number(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} ->
        f

      :error ->
        case Integer.parse(v) do
          {i, _} -> i
          _ -> 0
        end
    end
  end

  def to_number(v) when is_integer(v) or is_float(v), do: v
  def to_number(_), do: 0

  def to_decimal(input) when is_binary(input) do
    # Liquid semantics: floats only if pure float string; otherwise integer prefix allowed
    if Regex.match?(~r/\A-?\d+\.\d+\z/, input) do
      case Decimal.parse(input) do
        {d, ""} -> d
        _ -> @zero
      end
    else
      case Integer.parse(input) do
        {i, _} -> Decimal.new(i)
        _ -> @zero
      end
    end
  end

  def to_decimal(input) when is_integer(input), do: Decimal.new(input)
  def to_decimal(input) when is_float(input), do: Decimal.from_float(input)
  def to_decimal(%Decimal{} = input), do: input
  def to_decimal(_), do: @zero

  # Clamp variants
  def clamp(v, min, max) when is_number(v), do: min(max(v, min), max)
  def clamp(n) when n < 0, do: 0
  def clamp(n) when n > 255, do: 255
  def clamp(n), do: n

  # Binary search helpers
  def last_index(input, string) when is_binary(input) and is_binary(string) do
    input_len = byte_size(input)
    string_len = byte_size(string)

    if string_len == 0 do
      nil
    else
      0..(input_len - string_len)
      |> Enum.reverse()
      |> Enum.find(fn i ->
        :binary.part(input, i, string_len) == string
      end)
    end
  end

  def zero, do: @zero
end

defmodule Gas.Filters.Filter.Numeric do
  @moduledoc "Numeric filters: math, rounding, limits, aggregation"
  import Gas.Filters.Filter.Utils

  defp decimal_to_float(value) do
    value |> Decimal.normalize() |> Decimal.to_float()
  end

  defp try_decimal_to_integer(value) do
    if Decimal.integer?(value) do
      Decimal.to_integer(value)
    else
      decimal_to_float(value)
    end
  end

  defp original_float?(input) when is_float(input), do: true
  defp original_float?(input) when is_binary(input), do: Regex.match?(~r/\A-?\d+\.\d+\z/, input)
  defp original_float?(_), do: false

  # Arithmetic
  def abs(input) do
    input |> to_decimal() |> Decimal.abs() |> then(&try_decimal_to_integer(&1))
  end

  def plus(a, b) do
    Decimal.add(to_decimal(a), to_decimal(b))
    |> then(fn r ->
      if original_float?(a) or original_float?(b),
        do: decimal_to_float(r),
        else: try_decimal_to_integer(r)
    end)
  end

  def minus(a, b) do
    Decimal.sub(to_decimal(a), to_decimal(b))
    |> then(fn r ->
      if original_float?(a) or original_float?(b),
        do: decimal_to_float(r),
        else: try_decimal_to_integer(r)
    end)
  end

  def times(a, b) do
    Decimal.mult(to_decimal(a), to_decimal(b))
    |> then(fn r ->
      if original_float?(a) or original_float?(b),
        do: decimal_to_float(r),
        else: try_decimal_to_integer(r)
    end)
  end

  def divided_by(a, b) do
    db = to_decimal(b)

    if Decimal.equal?(db, zero()) do
      0
    else
      da = to_decimal(a)

      if original_float?(a) or original_float?(b) do
        Decimal.div(da, db) |> decimal_to_float()
      else
        Decimal.div_int(da, db) |> try_decimal_to_integer()
      end
    end
  end

  def modulo(a, b) do
    db = to_decimal(b)

    if Decimal.equal?(db, zero()) do
      0
    else
      da = to_decimal(a)
      r = Decimal.rem(da, db)

      if original_float?(a) or original_float?(b),
        do: decimal_to_float(r),
        else: try_decimal_to_integer(r)
    end
  end

  def ceil(x), do: x |> to_decimal() |> Decimal.round(0, :ceiling) |> to_string()
  def floor(x), do: x |> to_decimal() |> Decimal.round(0, :floor) |> to_string()

  def round(input, precision \\ nil)

  def round(input, precision) when is_binary(input) do
    p = to_integer(precision)

    input
    |> to_decimal()
    |> Decimal.round(p)
    |> then(fn r ->
      if original_float?(input) and p > 0,
        do: decimal_to_float(r),
        else: try_decimal_to_integer(r)
    end)
  end

  def round(input, _precision) when is_integer(input), do: input

  def round(input, precision) when is_float(input) do
    p = to_integer(precision)
    Decimal.from_float(input) |> Decimal.round(p) |> Decimal.normalize() |> to_string()
  end

  def round(_, _), do: 0

  # Limits
  def at_least(x, min), do: Decimal.max(to_decimal(x), to_decimal(min)) |> to_string()
  def at_most(x, max), do: Decimal.min(to_decimal(x), to_decimal(max)) |> to_string()

  # Aggregation
  def sum(enum, property \\ nil) do
    prop = if property, do: to_str(property), else: nil

    enum
    |> to_enum()
    |> Stream.map(fn v ->
      cond do
        prop == nil -> to_decimal(v)
        is_map(v) -> to_decimal(Map.get(v, prop, 0))
        is_binary(v) or is_boolean(v) or is_nil(v) -> Decimal.new(0)
        true -> raise %Gas.ArgumentError{message: "cannot select the property '#{prop}'"}
      end
    end)
    |> Enum.reduce(zero(), &Decimal.add/2)
    |> to_string()
  end
end

defmodule Gas.Filters.Filter.String do
  @moduledoc "String manipulation filters"
  import Gas.Filters.Filter.Utils

  # Basic concat
  def append(a, b), do: to_str(a) <> to_str(b)
  def prepend(a, b), do: to_str(b) <> to_str(a)

  # Case transforms
  def capitalize(x), do: to_str(x) |> String.capitalize()
  def upcase(x), do: to_str(x) |> String.upcase()
  def downcase(x), do: to_str(x) |> String.downcase()

  # Whitespace trims
  def lstrip(x), do: to_str(x) |> String.trim_leading()
  def rstrip(x), do: to_str(x) |> String.trim_trailing()
  def strip(x), do: to_str(x) |> String.trim()

  # Split/join
  def split(x, pat), do: String.split(to_str(x), to_str(pat), trim: true)
  def join(xs, glue \\ " "), do: xs |> to_enum() |> Enum.map_join(to_str(glue), &to_str/1)

  # Replace/remove family
  def remove(x, sub), do: String.replace(to_str(x), to_str(sub), "")
  def remove_first(x, sub), do: String.replace(to_str(x), to_str(sub), "", global: false)

  def replace(x, sub, repl \\ ""), do: String.replace(to_str(x), to_str(sub), to_str(repl))

  def replace_first(x, sub, repl \\ ""),
    do: String.replace(to_str(x), to_str(sub), to_str(repl), global: false)

  def remove_last(x, sub), do: replace_last(x, sub, "")

  def replace_last(input, sub, repl) do
    s = to_str(input)
    sub = to_str(sub)
    repl = to_str(repl)

    case Gas.Filters.Filter.Utils.last_index(s, sub) do
      nil ->
        if sub == "", do: s <> repl, else: s

      idx ->
        prefix = :binary.part(s, 0, idx)
        suffix = :binary.part(s, idx + byte_size(sub), byte_size(s) - (idx + byte_size(sub)))
        prefix <> repl <> suffix
    end
  end

  # Slice (string or list)
  def slice(input, offset, length \\ nil) do
    off = to_integer!(offset)
    len = if length, do: max(0, to_integer!(length)), else: 1

    if is_list(input),
      do: Enum.slice(input, off, len),
      else: to_str(input) |> String.slice(off, len)
  end

  # Truncation by chars
  def truncate(input, length \\ 50, ellipsis \\ "...") do
    len = to_integer!(length)
    s = to_str(input)
    e = to_str(ellipsis)

    if String.length(s) > len do
      take = max(0, len - String.length(e))
      slice(s, 0, take) <> e
    else
      s
    end
  end

  # Truncation by words
  def truncatewords(input, max_words \\ 15, ellipsis \\ "...")

  def truncatewords(nil, _max_words, _ellipsis), do: ""

  def truncatewords(input, max_words, ellipsis) do
    s = to_str(input)
    n = max(1, to_integer!(max_words))
    e = to_str(ellipsis)
    words = String.split(s, [" ", "\n", "\t"], trim: true)

    if length(words) > n do
      words = words |> Enum.take(n) |> Enum.intersperse(" ") |> to_string()

      words <> e
    else
      s
    end
  end
end

defmodule Gas.Filters.Filter.Collection do
  @moduledoc "Array and collection filters"
  require Gas.BinaryCondition
  import Gas.Filters.Filter.Utils

  def first(list) when is_list(list), do: List.first(list)
  def first(start.._//_), do: start

  def first(map) when is_map(map) do
    map |> Enum.take(1) |> hd() |> Tuple.to_list()
  end

  def first(_), do: nil

  def last(list) when is_list(list), do: List.last(list)
  def last(_..finish//_), do: finish
  def last(_), do: nil

  def compact(xs) when is_list(xs), do: Enum.reject(xs, &is_nil/1)
  def compact(x), do: compact([x])
  def compact(xs, prop) when is_list(xs), do: Enum.reject(xs, fn v -> v[prop] == nil end)

  def concat(a, b) when is_list(a) and is_list(b), do: List.flatten(a) ++ b
  def concat(a, b) when is_struct(a, Range), do: concat(Enum.to_list(a), b)
  def concat(a, b) when is_struct(b, Range), do: concat(a, Enum.to_list(b))
  def concat(nil, b) when is_list(b), do: concat([], b)
  def concat(a, b) when is_list(b), do: concat([a], b)

  def concat(_, _),
    do: raise(%Gas.ArgumentError{message: "concat filter requires an array argument"})

  def join(input, glue \\ " "),
    do: input |> to_enum() |> Enum.map_join(to_str(glue), &to_str/1)

  def reverse(input), do: input |> to_enum() |> Enum.reverse()

  def uniq(input), do: input |> to_enum() |> Enum.uniq()

  def sort(input), do: input |> to_enum() |> Enum.sort()

  def sort(input, key) do
    Enum.sort_by(input, fn element ->
      case map(element, key) do
        [head | _rest] ->
          head

        other ->
          other
      end
    end)
  end

  def sort_natural(input) when is_list(input) or is_struct(input, Range) do
    input
    |> to_enum()
    |> Enum.sort(&(String.downcase(to_string(&1)) <= String.downcase(to_string(&2))))
  end

  def sort_natural(input), do: to_string(input)

  def size(input) when is_binary(input), do: String.length(input)
  def size(range) when is_struct(range, Range), do: Enum.count(range)

  def size(input) when (not is_struct(input) and is_map(input)) or is_list(input),
    do: Enum.count(input)

  def size(_), do: 0

  def map(empty, _prop) when Gas.BinaryCondition.match_empty?(empty), do: []

  def map(input, prop) when is_binary(prop) do
    keys = String.split(prop, ".")

    case Gas.Matcher.match(input, keys) do
      {:ok, result} -> result |> List.wrap() |> List.flatten()
      _ -> []
    end
  end

  def map(_, prop),
    do: raise(%Gas.ArgumentError{message: "cannot select the property '#{prop}'"})

  def where_blank(input, key) do
    where(input, key, %Gas.Literal.Empty{})
  end

  def where(empty_input, _key, _value) when Gas.BinaryCondition.match_empty?(empty_input),
    do: []

  def where(input, key, value) when is_list(input) do
    Enum.filter(input, fn element ->
      comparison =
        case map(element, key) do
          [head | _rest] ->
            head

          _other ->
            []
        end

      Gas.BinaryCondition.eval({value, :==, comparison}) == {:ok, true}
    end)
  end

  def where(_input, _key, _value), do: []

  def values(%{} = map), do: Map.values(map)
  def values(other), do: List.wrap(other)

  def keys(%{} = map), do: Map.keys(map)
  def keys(_other), do: []

  def list(empty_input) when Gas.BinaryCondition.match_empty?(empty_input), do: []
  def list(entry), do: List.wrap(entry)

  def exists?(%{} = map, key) when is_map_key(map, key), do: true

  def exists?([_ | _] = list, key) do
    key in list
  end

  def exists?(_, _), do: false

  def decode_json(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, map} -> map
      {:error, _} -> %{}
    end
  end

  def decode_json(%{} = json), do: json

  def decode_json(_other) do
    %{}
  end

  def push(blank, input) when Gas.BinaryCondition.match_empty?(blank) and not is_list(blank),
    do: push([], input)

  def push(collection, blank) when Gas.BinaryCondition.match_empty?(blank), do: collection

  def push(collection, input) when is_list(collection) do
    List.insert_at(collection, -1, input)
  end

  def push(collection, input), do: push([collection], input)

  def push_if(collection, input, condition) do
    if Gas.BinaryCondition.eval({condition, :==, true}) == {:ok, true} do
      push(collection, input)
    else
      collection
    end
  end
end

defmodule Gas.Filters.Filter.Date do
  @moduledoc "Date/time filter"
  alias Gas.Literal.Empty

  def date(date, format) when format in [nil, ""] or format == %Empty{}, do: date

  def date(map, fmt) when is_map(map) and is_binary(fmt) do
    try do
      Calendar.strftime(map, fmt)
    rescue
      _ -> ""
    end
  end

  def date(unix, fmt) when is_integer(unix) do
    case DateTime.from_unix(unix, :second) do
      {:ok, dt} -> date(dt, fmt)
      _ -> ""
    end
  end

  def date(word, fmt) when word in ["now", "today"], do: date(NaiveDateTime.utc_now(), fmt)

  def date(str, fmt) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> date(dt, fmt)
      _ -> str
    end
  end

  def date(other, _fmt), do: other
end

defmodule Gas.Filters.Filter.Tel do
  @moduledoc """
  Phone filter: normalizes a number to E.164.

  Input carrying no international prefix loses its national trunk prefix `0`
  and takes the country calling code passed as the filter argument, falling
  back to `config :gas, default_country_code: "1"`. Input that cannot be
  normalized is returned unchanged.

      {{ "(555) 123-4567" | tel }}        #=> +15551234567
      {{ "020 7183 8750" | tel: "44" }}   #=> +442071838750
  """

  alias Gas.Literal.Empty

  @non_digits ~r/[^0-9]/
  @min_digits 8
  @max_digits 15
  @min_subscriber_digits 7

  def tel(input, country_code \\ nil)

  def tel(input, country_code) when is_binary(input) do
    case e164(String.trim(input), calling_code(country_code)) do
      {:ok, formatted} -> formatted
      :error -> input
    end
  end

  def tel(input, country_code) when is_integer(input),
    do: tel(Integer.to_string(input), country_code)

  def tel(other, _country_code), do: other

  defp e164("+" <> international, _code), do: validate(digits(international))
  defp e164("00" <> international, _code), do: validate(digits(international))
  defp e164(_national, ""), do: :error

  defp e164(national, code) do
    digits = digits(national)

    if String.starts_with?(digits, code) and
         byte_size(digits) - byte_size(code) >= @min_subscriber_digits do
      validate(digits)
    else
      validate(code <> strip_trunk_prefix(digits))
    end
  end

  defp strip_trunk_prefix("0" <> subscriber), do: subscriber
  defp strip_trunk_prefix(digits), do: digits

  defp validate(digits)
       when byte_size(digits) >= @min_digits and byte_size(digits) <= @max_digits,
       do: {:ok, "+" <> digits}

  defp validate(_digits), do: :error

  defp calling_code(code) when code in [nil, ""] or code == %Empty{},
    do: digits(to_string(Application.get_env(:gas, :default_country_code, "1")))

  defp calling_code(code), do: digits(to_string(code))

  defp digits(input), do: String.replace(input, @non_digits, "")
end

defmodule Gas.Filters.Filter.Color do
  @moduledoc "Color manipulation filters"
  import Gas.Filters.Filter.Utils

  def color_brightness(hex_color) do
    case parse_color(hex_color) do
      {:ok, {r, g, b, _a}} -> Float.round((r * 299 + g * 587 + b * 114) / 1000)
      _ -> 0
    end
  end

  def color_lighten(hex_color, percent), do: modify_color(hex_color, percent)
  def color_darken(hex_color, percent), do: modify_color(hex_color, -percent)

  def color_mix(hex1, hex2, percent \\ 50) do
    with {:ok, {r1, g1, b1, _a1}} <- parse_color(hex1),
         {:ok, {r2, g2, b2, _a2}} <- parse_color(hex2) do
      ratio = percent / 100
      r = round(r1 * (1 - ratio) + r2 * ratio)
      g = round(g1 * (1 - ratio) + g2 * ratio)
      b = round(b1 * (1 - ratio) + b2 * ratio)
      rgb_to_hex({r, g, b})
    else
      _ -> hex1
    end
  end

  defp modify_color(hex, percent) do
    case parse_color(hex) do
      {:ok, {r, g, b, _a}} ->
        shift = round(255 * percent / 100)
        r = clamp(r + shift)
        g = clamp(g + shift)
        b = clamp(b + shift)
        rgb_to_hex({r, g, b})

      _ ->
        hex
    end
  end

  defp rgb_to_hex({r, g, b}) do
    line =
      ("#" <>
         Integer.to_string(r, 16))
      |> String.pad_leading(2, "0")

    line =
      (line <>
         Integer.to_string(g, 16))
      |> String.pad_leading(2, "0")

    (line <>
       Integer.to_string(b, 16))
    |> String.pad_leading(2, "0")
  end

  # Advanced color_modify via HSL + alpha
  def color_modify(color, prop, value) when is_binary(color) do
    case parse_color(color) do
      {:ok, {r, g, b, a}} ->
        {h, s, l} = rgb_to_hsl(r, g, b)
        v = to_number(value)

        {h2, s2, l2, a2} =
          case String.downcase(to_string(prop)) do
            "hue" -> {normalize_hue(h + v), s, l, a}
            "saturation" -> {h, clamp(s + v, 0, 100), l, a}
            "lightness" -> {h, s, clamp(l + v, 0, 100), a}
            "alpha" -> {h, s, l, clamp(a + v, 0, 1)}
            _ -> {h, s, l, a}
          end

        {r2, g2, b2} = hsl_to_rgb(h2, s2, l2)
        rgba_to_hex({r2, g2, b2, a2})

      _ ->
        color
    end
  end

  def color_modify(_, _, _), do: nil

  def parse_color("rgba(" <> rest) do
    [r, g, b, a] =
      rest
      |> String.trim_trailing(")")
      |> String.split(",")
      |> Enum.map(fn chunk -> chunk |> String.trim() |> to_number() end)

    {:ok, {r, g, b, a}}
  end

  def parse_color("#" <> hex) do
    case String.length(hex) do
      3 ->
        [r, g, b] = String.graphemes(hex)
        {:ok, {hex_to_i(r <> r), hex_to_i(g <> g), hex_to_i(b <> b), 1.0}}

      6 ->
        {:ok,
         {hex_to_i(String.slice(hex, 0, 2)), hex_to_i(String.slice(hex, 2, 2)),
          hex_to_i(String.slice(hex, 4, 2)), 1.0}}

      8 ->
        {:ok,
         {hex_to_i(String.slice(hex, 0, 2)), hex_to_i(String.slice(hex, 2, 2)),
          hex_to_i(String.slice(hex, 4, 2)), hex_to_i(String.slice(hex, 6, 2)) / 255}}

      _ ->
        {:error, :invalid_hex}
    end
  end

  def parse_color(_), do: {:error, :unsupported_format}
  defp hex_to_i(h), do: String.to_integer(h, 16)

  # RGB <-> HSL
  defp rgb_to_hsl(r, g, b) when r == g and g == b do
    l = r / 255 * 100
    {0.0, 0.0, l}
  end

  defp rgb_to_hsl(r, g, b) do
    r = r / 255
    g = g / 255
    b = b / 255
    max = max(r, max(g, b))
    min = min(r, min(g, b))
    l = (max + min) / 2
    d = max - min
    s = if l > 0.5, do: d / (2 - max - min), else: d / (max + min)

    h =
      cond do
        max == r -> (g - b) / d + if g < b, do: 6, else: 0
        max == g -> (b - r) / d + 2
        max == b -> (r - g) / d + 4
      end

    {h * 60, s * 100, l * 100}
  end

  defp hsl_to_rgb(h, s, l) do
    h = h / 360
    s = s / 100
    l = l / 100

    if s == 0 do
      v = round(l * 255)
      {v, v, v}
    else
      q = if l < 0.5, do: l * (1 + s), else: l + s - l * s
      p = 2 * l - q

      {hue_to_rgb(p, q, h + 1 / 3), hue_to_rgb(p, q, h), hue_to_rgb(p, q, h - 1 / 3)}
      |> Tuple.to_list()
      |> Enum.map(&round(&1 * 255))
      |> List.to_tuple()
    end
  end

  defp hue_to_rgb(p, q, t) do
    t =
      cond do
        t < 0 -> t + 1
        t > 1 -> t - 1
        true -> t
      end

    cond do
      t < 1 / 6 -> p + (q - p) * 6 * t
      t < 1 / 2 -> q
      t < 2 / 3 -> p + (q - p) * (2 / 3 - t) * 6
      true -> p
    end
  end

  defp normalize_hue(h), do: rem(round(h), 360)

  defp rgba_to_hex({r, g, b, 1.0}), do: "#" <> Enum.map_join([r, g, b], "", &to_hex/1)

  defp rgba_to_hex({r, g, b, a}),
    do: "#" <> Enum.map_join([r, g, b, round(a * 255)], "", &to_hex/1)

  defp to_hex(v), do: v |> Integer.to_string(16) |> String.pad_leading(2, "0")
end

defmodule Gas.Filters.Filter.Asset do
  @moduledoc """
  Asset URL helpers. Two classes, each resolved through a host-injected seam:
  media (`image_url`) via `:asset_resolver`'s `fetch_url/2`, or `fetch_url/1`
  when the resolver does not export the two-arity form; theme
  (`asset_url`/`font_url`) via the `:theme_asset_url` `(path -> url)` fun.
  Both pass through unchanged when unconfigured.

  `image_url`'s `width` option reaches the resolver as `%{width: pos_integer}`,
  so the host can build a resizing URL such as an imageproxy `/300x/` prefix.

      config :gas,
        theme_assets_relative_path: "/theme/assets",
        asset_resolver: MyApp.Media,
        theme_asset_url: &MyAppWeb.Endpoint.static_path/1
  """

  import Gas.Filters.Filter.Utils

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  require Logger

  def image_url(invalid_link, _opts) when invalid_link in [nil, "", [""]], do: nil

  def image_url([head | _rest], opts), do: image_url(head, opts)

  def image_url(asset, opts) when is_binary(asset) do
    asset_location =
      with true <- Regex.match?(@uuid_regex, asset),
           url when is_binary(url) <- resolve_media_url(asset, media_opts(opts)) do
        url
      else
        _ -> asset
      end

    case URI.new(asset_location) do
      {:ok, uri} ->
        URI.to_string(uri)

      _ ->
        Logger.error("image_url not implemented yet #{inspect(asset)} #{inspect(opts)}")

        ""
    end
  end

  def asset_url(name, _kind \\ nil), do: theme_url(name)

  def font_url(src) when is_binary(src) and src != "", do: theme_url(src)
  def font_url(_), do: nil

  defp theme_url(name) do
    Application.get_env(:gas, :theme_assets_relative_path, "")
    |> Path.join(name)
    |> resolve_theme_url()
  end

  defp resolve_theme_url(path) do
    case Application.get_env(:gas, :theme_asset_url) do
      fun when is_function(fun, 1) -> fun.(path)
      _ -> path
    end
  end

  defp resolve_media_url(uuid, opts) do
    case Application.get_env(:gas, :asset_resolver) do
      nil -> nil
      mod -> fetch_url(mod, uuid, opts)
    end
  end

  defp fetch_url(mod, uuid, opts) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :fetch_url, 2) do
      mod.fetch_url(uuid, opts)
    else
      mod.fetch_url(uuid)
    end
  end

  defp media_opts(opts) when is_map(opts) do
    case to_integer(Map.get(opts, "width")) do
      width when width > 0 -> %{width: width}
      _ -> %{}
    end
  end

  defp media_opts(_opts), do: %{}
end

defmodule Gas.Filters.Filter.HTML do
  @moduledoc "HTML tag helpers"

  def preload_tag(url, opts \\ %{}) when is_binary(url) do
    as_value = Map.get(opts, "as", "style")
    ~s(<link rel="preload" href="#{url}" as="#{as_value}">)
  end

  def stylesheet_tag(url, opts \\ %{}) when is_binary(url) do
    media = Map.get(opts, "media", "all")
    ~s(<link rel="stylesheet" href="#{url}" media="#{media}">)
  end
end

defmodule Gas.Filters.Filter.Encoding do
  @moduledoc "Encoding, escaping, base64, JSON helpers"

  # HTML escaping
  def escape(iodata) do
    (iodata || "")
    |> IO.iodata_to_binary()
    |> Gas.HTML.html_escape()
  end

  @escape_once_regex ~r{["><']|&(?!([a-zA-Z]+|(#\d+));)}
  def escape_once(iodata) do
    (iodata || "")
    |> IO.iodata_to_binary()
    |> String.replace(@escape_once_regex, &Gas.HTML.replacements/1)
  end

  # HTML stripping
  @html_blocks ~r{(<script.*?</script>)|(<!--.*?-->)|(<style.*?</style>)}s
  @html_tags ~r|<.*?>|s
  def strip_html(iodata) do
    (iodata || "")
    |> IO.iodata_to_binary()
    |> String.replace(@html_blocks, "")
    |> String.replace(@html_tags, "")
  end

  # URL encode/decode
  def url_encode(iodata) do
    (iodata || "") |> IO.iodata_to_binary() |> URI.encode_www_form()
  end

  def url_decode(iodata) do
    (iodata || "") |> IO.iodata_to_binary() |> URI.decode_www_form()
  end

  # Newlines
  def strip_newlines(iodata) do
    binary = IO.iodata_to_binary(iodata || "")
    pattern = :binary.compile_pattern(["\r\n", "\n"])
    String.replace(binary, pattern, "")
  end

  def newline_to_br(iodata) when is_binary(iodata) do
    pattern = :binary.compile_pattern(["\r\n", "\n"])
    String.replace(iodata, pattern, "<br />\n")
  end

  def newline_to_br(_), do: nil

  # Base64
  def base64_encode(input), do: input |> to_string() |> Base.encode64()
  def base64_decode(nil), do: ""

  def base64_decode(input) do
    input |> IO.iodata_to_binary() |> Base.decode64!()
  end

  def base64_url_safe_encode(input), do: input |> to_string() |> Base.url_encode64()
  def base64_url_safe_decode(nil), do: ""

  def base64_url_safe_decode(input) do
    input |> IO.iodata_to_binary() |> Base.url_decode64!()
  end

  # JSON
  def json(data), do: structured_data(data)
  def structured_data(nil), do: "{}"
  def structured_data(other), do: JSON.encode!(other)

  # MD5
  def md5(args), do: :crypto.hash(:md5, args)
end

defmodule Gas.Filters.Filter.Logic do
  @moduledoc "Logical filters"
  alias Gas.Literal.Empty

  @empty_values [nil, false, [], "", %{}, %Empty{}]

  def default(input, value \\ "", opts \\ %{}) do
    allow_false = opts["allow_false"] || false

    case {input, value, allow_false} do
      {false, _, true} -> false
      {input, _, _} when input in @empty_values -> value
      _ -> input
    end
  end
end

defmodule Gas.Filters.Filter.Format do
  @moduledoc "Formatting filters like money"
  import Gas.Filters.Filter.Utils

  def money(input), do: money(input, [])

  def money(input, opts) do
    case currency() do
      nil ->
        symbol =
          case opts[:without_symbol] do
            true -> ""
            _ -> currency_symbol()
          end

        input
        |> to_decimal()
        |> money_format(symbol)

      module ->
        input
        |> to_integer()
        |> module.format!(opts || [])
    end
  end

  def money_without_trailing_zeros(input) do
    input |> money() |> String.replace(~r/\.00$/, "")
  end

  defp money_format(%Decimal{} = input, symbol),
    do: format_money_amount(Decimal.to_float(input), symbol)

  defp format_money_amount(amount, symbol) do
    formatted =
      amount
      |> :erlang.float_to_binary(decimals: 2)
      |> insert_thousands_separator()

    "#{symbol}#{formatted}"
  end

  defp insert_thousands_separator(<<>>), do: ""

  defp insert_thousands_separator(str) do
    [int_part, dec_part] = String.split(str, ".", parts: 2)

    int_with_commas =
      int_part
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    "#{int_with_commas}.#{dec_part}"
  end

  defp currency_symbol, do: "$"

  defp currency do
    Application.get_env(:gas, :currency)
  end
end

defmodule Gas.Filters.Filter.I18n do
  @moduledoc """
  Translation filters.
  """

  # Public API (Liquid filters)
  @spec t(term) :: String.t()
  def t(key), do: translate(key, %{})

  @spec t(term, map) :: String.t()
  def t(key, opts) when is_map(opts), do: translate(key, opts)
  def t(key, _opts), do: translate(key, %{})

  # Default translation behavior (pass-through)
  @spec translate(term, map) :: String.t()
  def translate(key, opts) do
    case translator() do
      nil ->
        nil

      module ->
        module.translation()
        |> get_nested_value(String.split(key, "."))
        |> replace_vars(opts)
    end
  end

  defp get_nested_value(map, [key]) when is_map(map) do
    Map.get(map, key)
  end

  defp get_nested_value(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      nested_map when is_map(nested_map) -> get_nested_value(nested_map, rest)
      other -> other
    end
  end

  defp replace_vars(nil, _vars), do: nil

  defp replace_vars(text, %{} = vars) when is_binary(text) do
    Enum.reduce(vars, text, fn {key, value}, acc ->
      String.replace(acc, "{{ #{key} }}", to_string(value))
    end)
  end

  defp replace_vars(text, _vars), do: text

  defp translator do
    Application.get_env(:gas, :translator)
  end
end

defmodule Gas.Filters.Filter do
  @moduledoc "Facade for all standard Liquid filters"

  # Import submodules
  alias Gas.Filters.Filter.{
    Numeric,
    Collection,
    Date,
    Tel,
    Color,
    Asset,
    HTML,
    Encoding,
    Logic,
    Format,
    I18n
  }

  # Delegates: numeric
  defdelegate abs(x), to: Numeric
  defdelegate plus(x, y), to: Numeric
  defdelegate minus(x, y), to: Numeric
  defdelegate times(x, y), to: Numeric
  defdelegate divided_by(x, y), to: Numeric
  defdelegate modulo(x, y), to: Numeric
  defdelegate ceil(x), to: Numeric
  defdelegate floor(x), to: Numeric
  defdelegate round(x, p \\ nil), to: Numeric
  defdelegate at_least(x, min), to: Numeric
  defdelegate at_most(x, max), to: Numeric
  defdelegate sum(enum, prop \\ nil), to: Numeric

  # Delegates: string
  defdelegate append(a, b), to: Gas.Filters.Filter.String
  defdelegate prepend(a, b), to: Gas.Filters.Filter.String
  defdelegate capitalize(x), to: Gas.Filters.Filter.String
  defdelegate upcase(x), to: Gas.Filters.Filter.String
  defdelegate downcase(x), to: Gas.Filters.Filter.String
  defdelegate lstrip(x), to: Gas.Filters.Filter.String
  defdelegate rstrip(x), to: Gas.Filters.Filter.String
  defdelegate strip(x), to: Gas.Filters.Filter.String
  defdelegate split(x, pat), to: Gas.Filters.Filter.String
  defdelegate join(xs, glue \\ " "), to: Gas.Filters.Filter.String
  defdelegate remove(x, sub), to: Gas.Filters.Filter.String
  defdelegate remove_first(x, sub), to: Gas.Filters.Filter.String
  defdelegate remove_last(x, sub), to: Gas.Filters.Filter.String

  defdelegate replace(x, sub, repl \\ ""),
    to: Gas.Filters.Filter.String

  defdelegate replace_first(x, sub, repl \\ ""),
    to: Gas.Filters.Filter.String

  defdelegate replace_last(x, sub, repl \\ ""),
    to: Gas.Filters.Filter.String

  defdelegate slice(x, off, len \\ nil),
    to: Gas.Filters.Filter.String

  defdelegate truncate(x, len \\ 50, ellipsis \\ "..."),
    to: Gas.Filters.Filter.String

  defdelegate truncatewords(x, n \\ 15, ellipsis \\ "..."),
    to: Gas.Filters.Filter.String

  # Delegates: collection
  defdelegate first(x), to: Collection
  defdelegate last(x), to: Collection
  defdelegate compact(x), to: Collection
  defdelegate compact(x, prop), to: Collection
  defdelegate concat(a, b), to: Collection
  defdelegate uniq(x), to: Collection
  defdelegate reverse(x), to: Collection
  defdelegate sort(x), to: Collection
  defdelegate sort(x, key), to: Collection
  defdelegate sort_natural(x), to: Collection
  defdelegate size(x), to: Collection
  defdelegate map(xs, prop), to: Collection
  defdelegate where_blank(xs, key), to: Collection
  defdelegate where(xs, key, val), to: Collection
  defdelegate values(map), to: Collection
  defdelegate keys(map), to: Collection
  defdelegate exists(map, key), to: Collection, as: :exists?
  defdelegate decode_json(json), to: Collection
  defdelegate list(input), to: Collection
  defdelegate push(collection, input), to: Collection
  defdelegate push_if(collection, input, condition), to: Collection

  # Delegates: date
  defdelegate date(x, fmt), to: Date
  defdelegate time_tag(x, fmt), to: Date, as: :date

  # Delegates: tel
  defdelegate tel(x, country_code \\ nil), to: Tel

  # Delegates: color
  defdelegate color_brightness(hex), to: Color
  defdelegate color_lighten(hex, pct), to: Color
  defdelegate color_darken(hex, pct), to: Color
  defdelegate color_mix(h1, h2, pct \\ 50), to: Color
  defdelegate color_modify(color, prop, value), to: Color

  # Delegates: asset + HTML
  defdelegate image_url(asset, opts), to: Asset
  defdelegate asset_url(asset), to: Asset
  defdelegate asset_url(asset, kind), to: Asset
  defdelegate font_url(font), to: Asset

  defdelegate preload_tag(url, opts \\ %{}), to: HTML
  defdelegate stylesheet_tag(url, opts \\ %{}), to: HTML

  # Delegates: encoding
  defdelegate escape(x), to: Encoding
  defdelegate escape_once(x), to: Encoding
  defdelegate strip_html(x), to: Encoding
  defdelegate url_encode(x), to: Encoding
  defdelegate url_decode(x), to: Encoding
  defdelegate strip_newlines(x), to: Encoding
  defdelegate newline_to_br(x), to: Encoding
  defdelegate base64_encode(x), to: Encoding
  defdelegate base64_decode(x), to: Encoding
  defdelegate base64_url_safe_encode(x), to: Encoding
  defdelegate base64_url_safe_decode(x), to: Encoding
  defdelegate json(x), to: Encoding
  defdelegate structured_data(x), to: Encoding
  defdelegate md5(x), to: Encoding

  # Delegates: logic/format
  defdelegate default(input, value \\ "", opts \\ %{}), to: Logic
  defdelegate money(input), to: Format
  defdelegate money_without_trailing_zeros(input), to: Format
  defdelegate money_with_currency(input), to: Format, as: :money

  def money_without_currency(input) do
    Format.money(input, without_symbol: true)
  end

  defdelegate t(key), to: I18n
  defdelegate t(key, opts), to: I18n
end
