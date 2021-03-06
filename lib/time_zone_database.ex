defmodule Tz.TimeZoneDatabase do
  @moduledoc false

  @behaviour Calendar.TimeZoneDatabase

  alias Tz.FileParser.ZoneRuleParser
  alias Tz.PeriodsGenerator.PeriodsBuilder
  alias Tz.PeriodsGenerator.PeriodsProvider
  alias Tz.PeriodsGenerator.Helper

  @impl true
  def time_zone_period_from_utc_iso_days(iso_days, time_zone) do
    unix_time = unix_time_from_iso_days(iso_days)

    with {:ok, periods} <- PeriodsProvider.periods(time_zone) do
      found_periods = find_periods_for_timestamp(periods, unix_time, :unix_time)

      found_periods =
        found_periods
        |> Enum.any?(& &1.to == :max)
        |> if do
             two_first_periods = Enum.take(periods, 2)

             if(Enum.count(two_first_periods, & &1.to == :max) == 2) do
               two_first_periods
               |> generate_dynamic_periods(DateTime.from_unix!(unix_time).year)
               |> find_periods_for_timestamp(unix_time, :unix_time)
             else
               found_periods
             end
           else
             found_periods
           end

      cond do
        Enum.count(found_periods) == 1 ->
          {:ok, List.first(found_periods)}
        true ->
          raise "#{Enum.count(found_periods)} periods found"
      end
    end
  end

  @impl true
  def time_zone_periods_from_wall_datetime(naive_datetime, time_zone) do
    gregorian_seconds = NaiveDateTime.diff(naive_datetime, ~N[0000-01-01 00:00:00])

    with {:ok, periods} <- PeriodsProvider.periods(time_zone) do
      found_periods = find_periods_for_timestamp(periods, gregorian_seconds, :wall_gregorian_seconds)

      found_periods =
        found_periods
        |> Enum.any?(& &1.to == :max)
        |> if do
            two_first_periods = Enum.take(periods, 2)

            if(Enum.count(two_first_periods, & &1.to == :max) == 2) do
              two_first_periods
              |> generate_dynamic_periods(naive_datetime.year)
              |> find_periods_for_timestamp(gregorian_seconds, :wall_gregorian_seconds)
            else
              found_periods
            end
          else
             found_periods
          end

      cond do
        Enum.count(found_periods) == 1 ->
          period = List.first(found_periods)
          case period do
            %{type: :gap} ->
              {:gap, {period.period_before_gap, period.from.wall}, {period.period_after_gap, period.to.wall}}
            _ ->
              {:ok, period}
          end
        Enum.count(found_periods) == 3 ->
          case Enum.at(found_periods, 1) do
            %{type: :overlap} ->
              {:ambiguous, Enum.at(found_periods, 0), Enum.at(found_periods, 2)}
            _ ->
              raise "#{Enum.count(found_periods)} periods found"
          end
        true ->
          raise "#{Enum.count(found_periods)} periods found"
      end
    end
  end

  defp generate_dynamic_periods([period1, period2], year) do
    rule1 =
      period1.raw_rule
      |> Map.put(:from_year, "#{year - 1}")
      |> Map.put(:to_year, "#{year + 1}")
      |> ZoneRuleParser.transform_rule()

    rule2 =
      period2.raw_rule
      |> Map.put(:from_year, "#{year - 1}")
      |> Map.put(:to_year, "#{year + 1}")
      |> ZoneRuleParser.transform_rule()

    rule_records =
      (rule1 ++ rule2)
      |> Enum.group_by(& &1.name)
      |> (fn rules_by_name ->
        rules_by_name
        |> Enum.map(fn {rule_name, rules} -> {rule_name, Helper.denormalize_rules(rules)} end)
        |> Enum.into(%{})
          end).()

    PeriodsBuilder.build_periods([period1.zone_line], rule_records)
    |> PeriodsBuilder.shrink_and_reverse_periods()
  end

  defp find_periods_for_timestamp(periods, timestamp, time_modifier, periods_found \\ [])

  defp find_periods_for_timestamp([], _timestamp, _, periods_found), do: periods_found

  defp find_periods_for_timestamp([period | rest_periods], timestamp, time_modifier, periods_found) do
    period_from = if(period.from == :min, do: :min, else: period.from[time_modifier])
    period_to = if(period.to == :max, do: :max, else: period.to[time_modifier])

    periods_found =
      if is_timestamp_in_range?(timestamp, period_from, period_to) do
        [period | periods_found]
      else
        periods_found
      end

    if is_timestamp_after_or_equal_date?(timestamp - 86400, period_from) do
      periods_found
    else
      find_periods_for_timestamp(rest_periods, timestamp, time_modifier, periods_found)
    end
  end

  defp is_timestamp_after_or_equal_date?(_, :min), do: true
  defp is_timestamp_after_or_equal_date?(_, :max), do: false
  defp is_timestamp_after_or_equal_date?(timestamp, date), do: timestamp >= date

  defp is_timestamp_in_range?(_, :min, :max), do: true
  defp is_timestamp_in_range?(timestamp, :min, date_to), do: timestamp < date_to
  defp is_timestamp_in_range?(timestamp, date_from, :max), do: timestamp >= date_from
  defp is_timestamp_in_range?(timestamp, date_from, date_to), do: timestamp >= date_from  && timestamp < date_to

  defp naive_datetime_from_iso_days(iso_days) do
    Calendar.ISO.naive_datetime_from_iso_days(iso_days)
    |> (&apply(NaiveDateTime, :new, Tuple.to_list(&1))).()
    |> elem(1)
  end

  defp unix_time_from_iso_days(iso_days) do
    naive_datetime_from_iso_days(iso_days)
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix()
  end
end
