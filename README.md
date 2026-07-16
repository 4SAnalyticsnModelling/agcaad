# AgCAAD

---

![AgCAAD](resource/agcaad.png)

AgCAAD is the Agriculture Crop Adaptation Atlas and Database used to rate the suitability of Alberta agricultural land for annual crop production from weather and soil information. The Phase 2 report, *Assessment of Agricultural Crop Suitability in Alberta in a Changing Climate*, describes AgCAAD as a model for evaluating crop suitability across Alberta townships using climate heat supply, moisture supply, soil physical conditions, soil chemical conditions, and drainage.

This repository contains a modernized AgCAAD command line model implemented in Zig. The GIS mapping workflow is intentionally out of scope; the model computes the crop suitability mathematics and writes the final tab-delimited suitability rating table.

## Features

- Runtime-sized, flat 1D array data structures.
- In-memory full-model execution with no intermediate suitability output files.
- Comma- or tab-delimited `.txt` inputs.
- One final tab-delimited `.txt` output file.
- Explicit `snake_case` input and output column names.
- Suitability limitation notes based on component scores.
- Modular soil, climate, and final-rating stages.
- Parallel crop-by-township climate scoring using available CPU threads.

## Download

Prebuilt binaries are available from the [`v1.0.0` release](https://github.com/4SAnalyticsnModelling/agcaad/releases/tag/v1.0.0).

Choose the archive for your operating system and CPU:

| Operating system | CPU | Download |
| --- | --- | --- |
| Windows | Intel/AMD 64-bit | [`x86_64-windows.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.0.0/x86_64-windows.zip) |
| Windows | ARM64 | [`aarch64-windows.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.0.0/aarch64-windows.zip) |
| Linux | Intel/AMD 64-bit | [`x86_64-linux.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.0.0/x86_64-linux.zip) |
| Linux | ARM64 | [`aarch64-linux.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.0.0/aarch64-linux.zip) |
| macOS | Intel 64-bit | [`x86_64-macos.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.0.0/x86_64-macos.zip) |
| macOS | Apple Silicon | [`aarch64-macos.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.0.0/aarch64-macos.zip) |

## Run With A Binary

Download and extract the archive for your system. The full model reads all required flat input files from a user-defined input folder and writes only the final ratings file to a user-defined output folder.
Create the output folder before running, then pass that folder as `<output-root>`.

Windows PowerShell:

```powershell
Expand-Archive .\x86_64-windows.zip -DestinationPath .\agcaad
New-Item -ItemType Directory -Force .\output
.\agcaad\bin\agcaad.exe run <input-root> .\output
```

Linux/macOS shell:

```sh
unzip x86_64-linux.zip -d agcaad
mkdir -p output
./agcaad/bin/agcaad run <input-root> ./output
```

Windows example using this repository's included example input:

```powershell
New-Item -ItemType Directory -Force ".\examples\agcaad_historical_weather_1981_2010\output"
.\agcaad\bin\agcaad.exe run `
  ".\examples\agcaad_historical_weather_1981_2010\input" `
  ".\examples\agcaad_historical_weather_1981_2010\output"
```

The final output is:

```text
crop_suitability_rankings_and_overall_ratings.txt
```

## Input Files

The example dataset is stored in:

```text
examples/
  agcaad_historical_weather_1981_2010/
    input/
      crop_suitability_requirements.txt
      historical_annual_precipitation_normals_by_township.txt
      historical_daily_temperature_normals_by_township.txt
      historical_hourly_temperature_by_township_day_hour.txt
      historical_winter_critical_temperature_by_township.txt
      soil_component_properties_by_township.txt
      soil_drainage_requirement_scores.txt
      soil_texture_requirement_scores.txt
      temperature_suitability_days_for_non_winter_crops.txt
      temperature_suitability_days_for_winter_crops.txt
```

Input folders should contain only the input `.txt` files. Nested input folders are not used.

## Output Columns

The full run writes one tab-delimited file with these columns:

- `crop_common_name`
- `township_id`
- `winter_cold_tolerance_score`
- `precipitation_suitability_score`
- `growing_season_suitability_score`
- `soil_drainage_suitability_score`
- `soil_ph_suitability_score`
- `soil_texture_suitability_score`
- `temperature_suitability_score`
- `overall_suitability_score`
- `overall_suitability_rating`
- `limitation_notes`

`limitation_notes` reports factors rated Moderately Suitable, Slightly Suitable, or Unsuitable, for example:

```text
May be limited by moisture, soil texture
```

## Suitability Classes

| Score range | Rating |
| --- | --- |
| `< 0.5` | Unsuitable |
| `0.5-1.49` | Slightly Suitable |
| `1.5-2.49` | Moderately Suitable |
| `2.5-3.5` | Suitable |
| `> 3.5` | Highly Suitable |

## Model Components

AgCAAD evaluates crop suitability from these component groups:

- Climate heat supply: growing season length, winter cold tolerance, and temperature suitability.
- Climate moisture supply: annual precipitation suitability.
- Soil physical conditions: soil texture.
- Soil chemical conditions: soil pH.
- Soil drainage: drainage class suitability.

The full `run` command computes all component scores in memory and writes only the final overall rating file.

## Stage Commands

Standalone stage commands are available for validation and debugging. These commands write their own tab-delimited stage output files.

```powershell
.\agcaad\bin\agcaad.exe texture <input-root> <output-root>
.\agcaad\bin\agcaad.exe ph <input-root> <output-root>
.\agcaad\bin\agcaad.exe drainage <input-root> <output-root>
.\agcaad\bin\agcaad.exe precip-score <input-root> <output-root>
.\agcaad\bin\agcaad.exe winter-cold <input-root> <output-root>
.\agcaad\bin\agcaad.exe growing-season <input-root> <output-root>
.\agcaad\bin\agcaad.exe temp-score <input-root> <output-root>
.\agcaad\bin\agcaad.exe final <input-root> <output-root>
```

On Linux and macOS, use `./agcaad/bin/agcaad` instead of `.\agcaad\bin\agcaad.exe`.

## Repository Layout

```text
src/
  agcaad.zig
  core/
    array_store.zig
    math.zig
    packed_key.zig
  io/
    delimited_reader.zig
    streaming_line_reader.zig
    tab_writer.zig
  soil/
    drainage.zig
    ph.zig
    texture.zig
  climate/
    growing_season.zig
    precip_suitability.zig
    temperature_suitability.zig
    winter_cold.zig
  suitability/
    final_rating.zig
```

## Build From Source

Source builds require Zig `0.16.0`.

```powershell
zig build
```

Run tests:

```powershell
zig build test
```

Run from source:

```powershell
zig build run -- run <input-root> <output-root>
```

## Notes

- The model uses prepared annual precipitation normals as an input file; it does not generate precipitation normals.
- The full run does not write intermediate suitability files.
- Numeric rounding uses Zig's default `@round` behavior.
- Climate suitability stages split crop-by-township calculations across available CPU threads.
