# Agriculture Crop Adaptation Atlas and Database (AgCAAD) Model

## Purpose

AgCAAD estimates how suitable each township is for each crop under rainfed or dryland agriculture. It combines four ordinary growing-condition scores with three climate constraints:

- hourly temperature;
- soil texture;
- soil drainage;
- soil pH;
- annual precipitation;
- growing-season length; and
- winter cold tolerance.

The result is a numeric score and one of five plain-language ratings. This document describes the implemented model precisely enough to reproduce it in another programming language.

## Basic concepts

A **crop** is identified by `crop_common_name`. A **map unit** is a township identified by `township_id`. A township may contain several soil components. Each soil component has an area fraction, and the fractions for one township must add to `1.0`, allowing a numerical tolerance of `0.001`.

Most component scores range from 0 to 4:

| Score | Meaning |
| ---: | --- |
| 0 | Unsuitable |
| 1 | Slightly suitable |
| 2 | Moderately suitable |
| 3 | Suitable |
| 4 | Highly suitable |

Hourly temperature is the exception: its optimum interval scores 5, as specified by the temperature equation. A township's final temperature score is therefore a mean between 0 and 5.

All comparisons below are exact. Words such as “greater than” and “greater than or equal to” are intentional because values exactly on a boundary can fall into a different class.

## Required inputs

Input files may be comma- or tab-delimited despite the `.txt` extension. Column order does not matter, but the names below must be present.

### `crop_suitability_requirements.txt`

One row per crop. The model uses these columns:

| Column | Meaning |
| --- | --- |
| `crop_common_name` | Crop identifier used in every output row |
| `growth_habit` | For example, `Annual`, `Winter Annual`, or `Perennial` |
| `absolute_minimum_temperature_celsius` | Temperature below which the crop receives an hourly score of 0; also used to delimit its active season |
| `optimum_minimum_temperature_celsius` | Lower edge of the optimum hourly interval |
| `optimum_maximum_temperature_celsius` | Upper edge of the optimum hourly interval |
| `absolute_maximum_temperature_celsius` | Temperature above which the crop receives an hourly score of 0 |
| `minimum_growing_days` | Minimum acceptable growing-season length |
| `maximum_growing_days` | Upper reference used to calculate the growing-day scoring range |
| `minimum_annual_precipitation_mm` | Lower crop precipitation requirement |
| `maximum_annual_precipitation_mm` | Upper crop precipitation requirement |
| `critical_minimum_winter_temperature_celsius` | Crop's critical winter minimum; may be blank where winter cold is not limiting |
| `minimum_soil_ph` | Lower pH requirement |
| `maximum_soil_ph` | Upper pH requirement |
| `soil_texture_requirement_code` | Joins the crop to the texture scoring table |
| `soil_drainage_requirement_code` | Joins the crop to the drainage scoring table |
| `soil_drainage_requirement_description` | Required descriptive field; it does not change the calculation |

Temperature thresholds must be ordered as:

```text
absolute minimum <= optimum minimum <= optimum maximum <= absolute maximum
```

Every maximum requirement must be at least its corresponding minimum.

### Weather inputs

`historical_annual_precipitation_normals_by_township.txt` contains:

- `township_id`
- `annual_precipitation_mm`

`historical_daily_temperature_normals_by_township.txt` contains:

- `township_id`
- `julian_day`
- `minimum_temperature_quantile_25_celsius`
- `maximum_temperature_quantile_25_celsius`
- `maximum_temperature_quantile_75_celsius`

`historical_hourly_temperature_by_township_day_hour.txt` requires:

- `township_id`
- `julian_day`
- `hourly_temperature_celsius`

An `hour_of_day` column may identify each record but is not used in the score. To reproduce the intended daily and annual means, provide the same number of hourly observations for every included day, normally 24.

`historical_winter_critical_temperature_by_township.txt` contains:

- `township_id`
- `minimum_temperature_quantile_05_celsius`

### Soil inputs

`soil_component_properties_by_township.txt` contains at least:

- `township_id`
- `soil_component_area_fraction`
- `soil_ph`
- `soil_drainage_code`
- `alberta_soil_texture_code`

Other descriptive soil columns may be present. Each fraction must be between 0 and 1, and all fractions belonging to a township must sum to `1.0 ± 0.001`.

`soil_texture_requirement_scores.txt` contains:

- `soil_texture_requirement_code`
- `alberta_soil_texture_code`
- `soil_texture_suitability_score`

`soil_drainage_requirement_scores.txt` contains:

- `soil_drainage_requirement_code`
- `soil_drainage_code`
- `soil_drainage_suitability_score`

The two scoring files must provide every requirement/code combination encountered by the model. Their scores must be between 0 and 4.

## Calculation order

For every crop and township, calculate the seven component scores described below. Then combine them using the final equation. Do not round intermediate values unless a section explicitly says to do so.

## 1. Soil pH

### Step 1: calculate one map-unit pH

First round each input component pH to two decimal places. For township soil components `j = 1...n`, let `a_j` be the component area fraction and `pH_j` its two-decimal pH. Calculate:

```text
map_unit_pH = sum(a_j × pH_j) / sum(a_j)
```

The denominator is retained for numerical robustness even though a valid township's fractions sum to 1.

Example: 75% of a township at pH 6 and 25% at pH 8 gives:

```text
(0.75 × 6) + (0.25 × 8) = 6.5
```

Classify the map-unit pH once. Do not classify each component and average those classes.

### Step 2: select the pH tolerance group

For crop minimum `pH_min` and maximum `pH_max`:

```text
range = pH_max - pH_min
mean  = (pH_min + pH_max) / 2
distance = absolute(map_unit_pH - mean)
```

Select thresholds by crop range:

| Crop pH range | Highly suitable | Suitable | Moderately suitable | Slightly suitable |
| --- | ---: | ---: | ---: | ---: |
| `range > 2` | distance `< 0.50` | `< 1.00` | `< 1.25` | `< 1.50` |
| `1 <= range <= 2` | distance `< 0.50` | `< 0.75` | `< 1.00` | `< 1.25` |
| `range < 1` | distance `< 0.25` | `< 0.55` | `< 0.75` | `< 0.85` |

Test the columns from left to right and assign scores 4, 3, 2, or 1. If none matches, assign 0. All inequalities are strict: a distance exactly equal to a threshold proceeds to the next class.

## 2. Soil texture

Texture is categorical, so the model does not average texture codes. For each soil component:

1. Read the crop's `soil_texture_requirement_code`.
2. Read the component's `alberta_soil_texture_code`.
3. Look up their score in `soil_texture_requirement_scores.txt`.
4. Multiply the score by the component area fraction.

Sum the contributions without intermediate rounding:

```text
texture_score = sum(component_texture_score_j × area_fraction_j)
```

## 3. Soil drainage

Drainage is calculated in the same way as texture, using the drainage lookup table:

```text
drainage_score = sum(component_drainage_score_j × area_fraction_j)
```

The lookup key is `(soil_drainage_requirement_code, soil_drainage_code)`. Do not round component contributions before summing.

## 4. Annual precipitation

Let:

```text
P = township annual precipitation
L = crop minimum annual precipitation
U = crop maximum annual precipitation
R = U - L
```

Rules are evaluated from score 4 down to score 1. The first matching rule wins; otherwise the score is 0. This evaluation order matters because some intervals overlap.

### Wide precipitation range: `R >= 300`

| Score | Condition |
| ---: | --- |
| 4 | `P >= L + R/3` and `P <= U + 1.25R` |
| 3 | `P >= L` and `P <= U + 1.25R` |
| 2 | `P >= L - 150` and `P <= U + 1.6R` |
| 1 | `P >= L - 350` and `P <= U + 1.8R` |
| 0 | none of the above |

### Narrow precipitation range: `R < 300`

| Score | Condition |
| ---: | --- |
| 4 | `P >= L + R/3` and `P <= U + 350` |
| 3 | `P >= L` and `P <= U + 350` |
| 2 | `P >= L - R/3` and `P <= U + 480` |
| 1 | `P >= L - 2R/3` and `P <= U + 600` |
| 0 | none of the above |

Example for `L = 150`, `U = 450`, and `R = 300`: precipitation of 150 scores 3, 250 through 825 scores 4, 826 through 930 scores 2, 931 through 990 scores 1, and 991 scores 0.

## 5. Winter cold tolerance

The township weather value is its fifth-percentile winter minimum temperature, `T_winter`. The crop value is its critical minimum, `T_critical`.

Assign 4 immediately if the critical minimum is blank or if `growth_habit` is exactly one of:

- `Annual`
- `Functional Annual/Biennial`
- `Annual/Biennial/Perennial`
- `Annual/Perennial`

These are exact category names, not a general exemption for every biennial or perennial. The composite categories identify crops that the model treats as annual production systems—for example, a perennial species grown and harvested as an annual—so winter survival is not considered limiting. Crops labelled simply `Biennial`, `Biennial/Perennial`, or `Perennial` are evaluated against their critical winter minimum using the table below.

Otherwise:

| Score | Condition |
| ---: | --- |
| 4 | `T_winter > T_critical + 3` |
| 3 | `T_winter > T_critical + 2` |
| 2 | `T_winter > T_critical + 1` |
| 1 | `T_winter >= T_critical` |
| 0 | `T_winter < T_critical` |

## 6. Growing-season length

Winter annual crops receive a growing-season score of 4 without counting days.

For every other crop, sort daily normals by township and Julian day. A day satisfies both growing conditions when:

```text
maximum_temperature_quantile_75_celsius > crop absolute minimum
and
minimum_temperature_quantile_25_celsius > 0
```

The growing season is the continuous intersection of those two conditions:

1. Before day 184, a short qualifying interval followed by a non-qualifying day is treated as a winter thaw. Discard its accumulated days and continue looking for the true season.
2. Once a qualifying interval continues past midyear, count each qualifying day.
3. On or after day 184, the first non-qualifying day ends the season permanently. Do not count that day and do not restart after a later warm spell.

Let `D` be the resulting number of days, `G_min` the crop minimum growing days, and:

```text
G_range = maximum_growing_days - minimum_growing_days
```

Assign:

| Score | Condition |
| ---: | --- |
| 0 | `D < G_min` |
| 1 | `G_min <= D < G_min + 0.125G_range` |
| 2 | `G_min + 0.125G_range <= D < G_min + 0.25G_range` |
| 3 | `G_min + 0.25G_range <= D < G_min + 0.375G_range` |
| 4 | `D >= G_min + 0.375G_range` |

## 7. Temperature suitability

Temperature suitability has two stages: identify the days when the crop is active, then score every hourly temperature on those days.

### Active days for crops other than winter annuals

Use the same two daily conditions as the growing-season calculation:

```text
daily maximum 75th percentile > crop absolute minimum
daily minimum 25th percentile > 0
```

Ignore qualifying winter-thaw intervals that end before or on day 183. After midyear, the first failure ends the active period permanently.

### Active days for winter annuals

The calendar is processed in two halves.

For days 1 through 183:

1. The crop remains dormant until both `maximum_temperature_quantile_25_celsius > absolute minimum` and `minimum_temperature_quantile_25_celsius > 0`.
2. Days are active after both dormancy-end conditions hold.
3. The first day with `maximum_temperature_quantile_25_celsius > optimum maximum` is the harvest boundary. That day is excluded, and no later day in the first half is active.

For day 184 onward, reset to the pre-planting state:

1. Wait while `maximum_temperature_quantile_75_celsius > optimum maximum`.
2. The first day at or below that threshold begins the fall active period, subject to the dormancy tests below.
3. Dormancy begins when either `maximum_temperature_quantile_75_celsius <= absolute minimum` or `minimum_temperature_quantile_25_celsius < 0`. The boundary day is excluded, and the crop remains dormant for the rest of the year.

These 25th- and 75th-percentile thresholds represent the probability rules used for winter planting, harvest, and dormancy.

### Hourly score

For each hourly temperature `T` on an active day:

| Score | Temperature interval |
| ---: | --- |
| 0 | `T < absolute minimum` |
| 3 | `absolute minimum <= T < optimum minimum` |
| 5 | `optimum minimum <= T <= optimum maximum` |
| 3 | `optimum maximum < T <= absolute maximum` |
| 0 | `T > absolute maximum` |

Sum the hourly scores and divide by the number of scored hourly records:

```text
temperature_score = sum(hourly scores) / number of scored hours
```

Round this mean to one decimal. That one-decimal temperature score is displayed and passed to the final calculation.

## Final suitability score

Let:

```text
T = temperature score
X = texture score
D = drainage score
H = pH score
P = precipitation score
G = growing-season score
W = winter cold score
```

First calculate the ordinary-condition mean:

```text
base = (T + X + D + H) / 4
```

Then calculate the multiplicative climate constraint:

```text
constraint = cube_root((P × G × W) / 64)
```

The denominator is `64 = 4 × 4 × 4`. The exponent is an exact cube root, not decimal exponent 0.3.

Finally:

```text
overall_score = round_to_one_decimal(base × constraint)
```

Rounding is conventional half-away-from-zero decimal rounding. The rounded score is used for the final rating.

Example: if `T = X = D = H = 4`, `P = 4`, `G = 2`, and `W = 4`:

```text
base = 4
constraint = cube_root(32 / 64) = cube_root(0.5)
overall_score = round_to_one_decimal(4 × cube_root(0.5)) = 3.2
rating = Suitable
```

## Final rating

| Rounded overall score | Rating |
| ---: | --- |
| `< 0.5` | Unsuitable |
| `>= 0.5` and `< 1.5` | Slightly Suitable |
| `>= 1.5` and `< 2.5` | Moderately Suitable |
| `>= 2.5` and `< 3.5` | Suitable |
| `>= 3.5` | Highly Suitable |

## Limitation notes

Each component is independently translated through the same rating thresholds. Components rated Unsuitable, Slightly Suitable, or Moderately Suitable are listed as possible limitations in this order:

1. winter cold;
2. moisture;
3. growing season length;
4. soil drainage;
5. soil pH;
6. soil texture; and
7. heat.

If no component falls below Suitable, the note is `No major limitation identified`.
