defmodule Tz.PeriodsGenerator.PeriodsBuilder do
  @moduledoc false

  require Tz.PeriodsGenerator.Helper
  import Tz.PeriodsGenerator.Helper

  def build_periods(zone_lines, rule_records, prev_period \\ nil, periods \\ [])

  def build_periods([], _rule_records, _prev_period, periods), do: periods

  def build_periods([zone_line | rest_zone_lines], rule_records, prev_period, periods) do
    rules = Map.get(rule_records, zone_line.rules, zone_line.rules)

    new_periods = build_periods_for_zone_line(zone_line, rules, prev_period)

    build_periods(rest_zone_lines, rule_records, List.last(new_periods), periods ++ new_periods)
  end

  defp offset_diff_from_prev_period(_zone_line, _local_offset, nil), do: 0
  defp offset_diff_from_prev_period(zone_line, local_offset, prev_period) do
    total_offset = zone_line.std_offset_from_utc_time + local_offset
    prev_total_offset = prev_period.std_offset_from_utc_time + prev_period.local_offset_from_std_time
    total_offset - prev_total_offset
  end

  defp maybe_build_gap_or_overlap_period(_zone_line, _local_offset, %{to: :max}, _period), do: nil
  defp maybe_build_gap_or_overlap_period(zone_line, local_offset, prev_period, period) do
    offset_diff = offset_diff_from_prev_period(zone_line, local_offset, prev_period)

    if offset_diff > 0 do
      if period.from.unix_time != prev_period.to.unix_time do
        raise "logic error"
      end

      %{
        type: :gap,
        period_before_gap: prev_period,
        period_after_gap: period,
        from: prev_period.to,
        to: period.from
      }
    else
      if offset_diff < 0 do
        if period.from.unix_time != prev_period.to.unix_time do
          raise "logic error"
        end

        %{
          type: :overlap,
          from: period.from,
          to: prev_period.to
        }
      end
    end
  end

  defp build_periods_for_zone_line(zone_line, offset, prev_period) when is_integer(offset) do
    if zone_line.from != :min && prev_period != nil do
      {zone_from, zone_from_modifier} = zone_line.from
      if prev_period.to[zone_from_modifier] != zone_from do
        raise "logic error"
      end
    end

    offset_diff = offset_diff_from_prev_period(zone_line, offset, prev_period)

    period_from =
      if zone_line.from == :min do
        :min
      else
        add_to_and_convert_date_tuple({prev_period.to.wall, :wall}, offset_diff, zone_line.std_offset_from_utc_time, offset)
      end

    period = %{
      type: :regular,
      from: period_from,
      to: convert_date_tuple(zone_line.to, zone_line.std_offset_from_utc_time, offset),
      std_offset_from_utc_time: zone_line.std_offset_from_utc_time,
      local_offset_from_std_time: offset,
      zone_abbr: zone_line.format_time_zone_abbr
    }

    maybe_gap_or_overlap_period = maybe_build_gap_or_overlap_period(zone_line, offset, prev_period, period)

    if maybe_gap_or_overlap_period, do: [maybe_gap_or_overlap_period, period], else: [period]
  end

  defp build_periods_for_zone_line(zone_line, rules, prev_period) when is_list(rules) do
    if zone_line.from != :min && prev_period != nil do
      {zone_from, zone_from_modifier} = zone_line.from
      if prev_period.to[zone_from_modifier] != zone_from do
        raise "logic error"
      end
    end

    zone_line_rules =
      if(zone_line.from == :min && zone_line.to == :max) do
        rules
      else
        filter_rules_for_zone_line(zone_line, rules, prev_period, if(prev_period == nil, do: 0, else: prev_period.local_offset_from_std_time))
      end

    zone_line_rules = maybe_pad_left_rule(zone_line, zone_line_rules, prev_period)

    zone_line_rules = trim_zone_rules(zone_line, zone_line_rules, prev_period)

    do_build_periods_for_zone_line(zone_line, zone_line_rules, prev_period, [])
  end

  defp filter_rules_for_zone_line(zone_line, rules, prev_period, prev_local_offset_from_std_time, filtered_rules \\ [])
  defp filter_rules_for_zone_line(_zone_line, [], _, _, filtered_rules), do: filtered_rules
  defp filter_rules_for_zone_line(zone_line, [rule | rest_rules], prev_period, prev_local_offset_from_std_time, filtered_rules) do
    is_rule_included =
      cond do
        zone_line.to == :max && rule.to == :max ->
          true
        zone_line.to == :max ->
          {rule_to, rule_to_modifier} = rule.to

          if prev_period == nil do
            true
          else
            NaiveDateTime.compare(prev_period.to[rule_to_modifier], rule_to) == :lt
          end
        zone_line.from == :min || rule.to == :max ->
          {zone_to, zone_to_modifier} = zone_line.to
          rule_from = convert_date_tuple(rule.from, prev_period.std_offset_from_utc_time, prev_local_offset_from_std_time)

          NaiveDateTime.compare(zone_to, rule_from[zone_to_modifier]) == :gt
        true ->
          {zone_to, zone_to_modifier} = zone_line.to
          {rule_to, rule_to_modifier} = rule.to
          rule_from = convert_date_tuple(rule.from, prev_period.std_offset_from_utc_time, prev_local_offset_from_std_time)

          NaiveDateTime.compare(prev_period.to[rule_to_modifier], rule_to) == :lt
          && NaiveDateTime.compare(zone_to, rule_from[zone_to_modifier]) == :gt
      end

    if is_rule_included do
      filter_rules_for_zone_line(zone_line, rest_rules, prev_period, rule.local_offset_from_std_time, filtered_rules ++ [rule])
    else
      filter_rules_for_zone_line(zone_line, rest_rules, prev_period, prev_local_offset_from_std_time, filtered_rules)
    end
  end

  defp trim_zone_rules(_zone_line, [], _), do: []
  defp trim_zone_rules(zone_line, rules, prev_period) do
    first_rule = List.first(rules)

    rules =
      if rule_starts_before_zone_line_range?(zone_line, first_rule, if(prev_period == nil, do: 0, else: prev_period.local_offset_from_std_time)) do
        [%{first_rule | from: zone_line.from} | tl(rules)]
      else
        rules
      end

    last_rule = List.last(rules)

    if rule_ends_after_zone_line_range?(zone_line, last_rule) do
      rules_without_last = Enum.reverse(rules) |> tl() |> Enum.reverse()
      rules_without_last ++ [%{last_rule | to: zone_line.to}]
    else
      rules
    end
  end

  defp rule_starts_before_zone_line_range?(%{from: :min}, _rule, _), do: false
  defp rule_starts_before_zone_line_range?(zone_line, rule, prev_local_offset_from_std_time) do
    rule_from = convert_date_tuple(rule.from, zone_line.std_offset_from_utc_time, prev_local_offset_from_std_time)
    %{from: {zone_from, zone_from_modifier}} = zone_line
    NaiveDateTime.compare(rule_from[zone_from_modifier], zone_from) == :lt
  end

  defp rule_ends_after_zone_line_range?(%{to: :max}, _rule), do: false
  defp rule_ends_after_zone_line_range?(_zone_line, %{to: :max}), do: true
  defp rule_ends_after_zone_line_range?(zone_line, rule) do
    rule_to = convert_date_tuple(rule.to, zone_line.std_offset_from_utc_time, rule.local_offset_from_std_time)
    %{to: {zone_to, zone_to_modifier}} = zone_line
    NaiveDateTime.compare(rule_to[zone_to_modifier], zone_to) == :gt
  end

  defp maybe_pad_left_rule(_zone_line, [], _), do: []

  defp maybe_pad_left_rule(%{from: :min}, [first_rule | _] = rules, _) do
    rule = %{
      record_type: :rule,
      from: :min,
      name: "",
      local_offset_from_std_time: 0,
      letter: Enum.find(rules, & &1.local_offset_from_std_time == 0).letter,
      to: first_rule.from
    }
    [rule | rules]
  end

  defp maybe_pad_left_rule(_zone_line, rules, nil), do: rules

  defp maybe_pad_left_rule(zone_line, [first_rule | _] = rules, prev_period) do
    {rule_from, rule_from_modifier} = first_rule.from

    if NaiveDateTime.compare(prev_period.to[rule_from_modifier], rule_from) == :lt do
      rule = %{
        record_type: :rule,
        from: zone_line.from,
        name: first_rule.name,
        local_offset_from_std_time: 0,
        letter: "",
        to: first_rule.from
      }
      [rule | rules]
    else
      rules
    end
  end

  defp do_build_periods_for_zone_line(_zone_line, [], _prev_period, periods), do: periods

  defp do_build_periods_for_zone_line(zone_line, [rule | rest_rules], prev_period, periods) do
    offset_diff = offset_diff_from_prev_period(zone_line, rule.local_offset_from_std_time, prev_period)

    period_from =
      case prev_period do
        nil ->
          convert_date_tuple(zone_line.from, zone_line.std_offset_from_utc_time, 0)
        %{to: :max} ->
          convert_date_tuple(rule.from, zone_line.std_offset_from_utc_time, prev_period.local_offset_from_std_time)
        _ ->
          add_to_and_convert_date_tuple({prev_period.to.wall, :wall}, offset_diff, zone_line.std_offset_from_utc_time, rule.local_offset_from_std_time)
      end

    period_to = convert_date_tuple(rule.to, zone_line.std_offset_from_utc_time, rule.local_offset_from_std_time)

    if period_from != :min && period_to != :max && period_from.unix_time == period_to.unix_time do
      raise "logic error"
    end

    period = %{
      type: :regular,
      from: period_from,
      to: period_to,
      std_offset_from_utc_time: zone_line.std_offset_from_utc_time,
      local_offset_from_std_time: rule.local_offset_from_std_time,
      zone_abbr: zone_abbr(zone_line, rule)
    }

    period =
      if period_to == :max do
        period
        |> Map.put(:raw_rule, rule.raw)
        |> Map.put(:zone_line, zone_line)
      else
        period
      end

    maybe_gap_or_overlap_period = maybe_build_gap_or_overlap_period(zone_line, rule.local_offset_from_std_time, prev_period, period)

    periods = if maybe_gap_or_overlap_period, do: periods ++ [maybe_gap_or_overlap_period], else: periods

    periods = periods ++ [period]

    do_build_periods_for_zone_line(zone_line, rest_rules, period, periods)
  end

  defp zone_abbr(zone_line, rule) do
    is_standard_time = rule.local_offset_from_std_time == 0

    cond do
      String.contains?(zone_line.format_time_zone_abbr, "/") ->
        [zone_abbr_std_time, zone_abbr_dst_time] = String.split(zone_line.format_time_zone_abbr, "/")
        if(is_standard_time, do: zone_abbr_std_time, else: zone_abbr_dst_time)
      String.contains?(zone_line.format_time_zone_abbr, "%s") ->
        String.replace(zone_line.format_time_zone_abbr, "%s", rule.letter)
      true ->
        zone_line.format_time_zone_abbr
    end
  end

  defp add_to_and_convert_date_tuple(:min, _, _, _), do: :min
  defp add_to_and_convert_date_tuple(:max, _, _, _), do: :max
  defp add_to_and_convert_date_tuple({date, time_modifier}, add_seconds, std_offset_from_utc_time, local_offset_from_std_time) do
    date = NaiveDateTime.add(date, add_seconds, :second)
    convert_date_tuple({date, time_modifier}, std_offset_from_utc_time, local_offset_from_std_time)
  end

  defp convert_date_tuple(:min, _, _), do: :min
  defp convert_date_tuple(:max, _, _), do: :max
  defp convert_date_tuple({date, time_modifier}, std_offset_from_utc_time, local_offset_from_std_time) do
    map_of_dates = %{
      wall: convert_date(date, std_offset_from_utc_time, local_offset_from_std_time, time_modifier, :wall),
      utc: convert_date(date, std_offset_from_utc_time, local_offset_from_std_time, time_modifier, :utc),
      standard: convert_date(date, std_offset_from_utc_time, local_offset_from_std_time, time_modifier, :standard)
    }

    unix_time =
      DateTime.from_naive!(map_of_dates.utc, "Etc/UTC")
      |> DateTime.to_unix()

    map_of_dates
    |> Map.put(:unix_time, unix_time)
    |> Map.put(:wall_gregorian_seconds, NaiveDateTime.diff(map_of_dates.wall, ~N[0000-01-01 00:00:00]))
  end

  def shrink_and_reverse_periods(periods, shrank_periods \\ [])

  def shrink_and_reverse_periods([], shrank_periods), do: shrank_periods

  def shrink_and_reverse_periods([period | tail], shrank_periods) do
    {local_offset_from_std_time, period} = pop_in(period, [:local_offset_from_std_time])
    period = Map.put(period, :std_offset, local_offset_from_std_time)

    {std_offset_from_utc_time, period} = pop_in(period, [:std_offset_from_utc_time])
    period = Map.put(period, :utc_offset, std_offset_from_utc_time)

    period =
      if period.type == :gap do
        {local_offset_from_std_time, period} = pop_in(period, [:period_before_gap, :local_offset_from_std_time])
        period = put_in(period, [:period_before_gap, :std_offset], local_offset_from_std_time)

        {std_offset_from_utc_time, period} = pop_in(period, [:period_before_gap, :std_offset_from_utc_time])
        period = put_in(period, [:period_before_gap, :utc_offset], std_offset_from_utc_time)

        {local_offset_from_std_time, period} = pop_in(period, [:period_after_gap, :local_offset_from_std_time])
        period = put_in(period, [:period_after_gap, :std_offset], local_offset_from_std_time)

        {std_offset_from_utc_time, period} = pop_in(period, [:period_after_gap, :std_offset_from_utc_time])
        put_in(period, [:period_after_gap, :utc_offset], std_offset_from_utc_time)
      else
        period
      end

    period =
      if period.from != :min do
        {_, period} = pop_in(period, [:from, :standard])
        {_, period} = pop_in(period, [:from, :utc])
        period
      else
        period
      end

    period =
      if period.from != :min && period.type != :gap do
        {_, period} = pop_in(period, [:from, :wall])
        period
      else
        period
      end

    period =
      if period.to != :max do
        {_, period} = pop_in(period, [:to, :standard])
        {_, period} = pop_in(period, [:to, :utc])
        period
      else
        period
      end

    period =
      if period.to != :max && period.type != :gap do
        {_, period} = pop_in(period, [:to, :wall])
        period
      else
        period
      end

    {_, period} = pop_in(period, [:period_before_gap, :from])
    {_, period} = pop_in(period, [:period_before_gap, :to])
    {_, period} = pop_in(period, [:period_before_gap, :type])
    {_, period} = pop_in(period, [:period_after_gap, :from])
    {_, period} = pop_in(period, [:period_after_gap, :to])
    {_, period} = pop_in(period, [:period_after_gap, :type])

    shrink_and_reverse_periods(tail, [period | shrank_periods])
  end
end
