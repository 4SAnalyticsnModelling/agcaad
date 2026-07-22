![AgCAAD](resource/agcaad.png)

# AgCAAD


The **Agriculture Crop Adaptation Atlas and Database (AgCAAD)** is used to rate the suitability of Alberta agricultural land for annual crop production from weather and soil information. 
The AgCAAD model evaluates crop suitability across Alberta townships using climate heat supply, moisture supply, soil physical conditions, soil chemical conditions, and drainage. 

For a plain-language, reproducible explanation of the model, see [AgCAAD model description](docs/AgCAAD_model_description.md).

## Model Components

AgCAAD evaluates crop suitability from these component groups:

- Climate heat supply: growing season length, winter cold tolerance, and temperature suitability.
- Climate moisture supply: annual precipitation suitability.
- Soil physical conditions: soil texture.
- Soil chemical conditions: soil pH.
- Soil drainage: drainage class suitability.

## High Performance Parallel Computing

AgCAAD distributes computations across township grids and crops. The optional `--threads` argument defaults to `1`. Use `--threads auto` to use the available CPU cores, or provide a positive integer to set the worker count.

## Interactive Web Application

**[AgCAAD Explorer](https://www.4sanalyticsnmodelling.com/agcaad-explorer/)** lets you explore crop suitability maps, and generate suitability assessments through a modern web interface.

## Download

Prebuilt binaries are available from the [`v1.2.0` release](https://github.com/4SAnalyticsnModelling/agcaad/releases/tag/v1.2.0).

The example input dataset is available separately as [`examples.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.2.0/examples.zip).

Choose the archive for your operating system and CPU:

| Operating system | CPU | Download |
| --- | --- | --- |
| Windows | Intel/AMD 64-bit | [`x86_64-windows.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.2.0/x86_64-windows.zip) |
| Windows | ARM64 | [`aarch64-windows.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.2.0/aarch64-windows.zip) |
| Linux | Intel/AMD 64-bit | [`x86_64-linux.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.2.0/x86_64-linux.zip) |
| Linux | ARM64 | [`aarch64-linux.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.2.0/aarch64-linux.zip) |
| macOS | Intel 64-bit | [`x86_64-macos.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.2.0/x86_64-macos.zip) |
| macOS | Apple Silicon | [`aarch64-macos.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.2.0/aarch64-macos.zip) |

## Run With A Binary

Download and extract the archive for your system. The full model reads all required flat input files from a user-defined input folder and writes only the final ratings file to a user-defined output folder.
Pass the input and output folders as named arguments. The optional `--threads` argument defaults to `1`; use `--threads auto` to use the available logical CPU cores, or provide a positive integer. AgCAAD creates the output folder when needed.

Windows PowerShell:

```powershell
.\agcaad.exe --input <input-root> --output <output-root> [--threads <auto|number>]
```

Linux/macOS shell:

```sh
chmod 'u+x' agcaad
./agcaad --input <input-root> --output <output-root> [--threads <auto|number>]
```

If `--threads` is omitted, the model runs with one worker thread. For example:

```powershell
.\agcaad.exe --input <input-root> --output <output-root>
```

Windows example after downloading and extracting `examples.zip`:

```powershell
.\agcaad.exe --input "examples\agcaad_historical_weather_1981_2010\input" --output "examples\agcaad_historical_weather_1981_2010\output" --threads auto
```
On Linux and macOS, use `./agcaad` instead of `.\agcaad.exe`.

The final output is:

```text
crop_suitability_rankings_and_overall_ratings.txt
```

## Input Files

After extracting [`examples.zip`](https://github.com/4SAnalyticsnModelling/agcaad/releases/download/v1.2.0/examples.zip), the example dataset has this layout:

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
```

Temperature-suitability growing days are calculated for all crops from the daily temperature normals; no precomputed crop-day files are required. Input folders should contain only the input `.txt` files. Nested input folders are not used.

The calculations follow *Appendix D: Model to Determine Suitability of a Region for a Large Number of Crops* (2004). In particular, optimum hourly temperature has score 5 (the prose reference to a 0-4 temperature scale is a typo), the final climatic multiplier is a cube root, winter-annual planting/harvest and dormancy use the specified 25th/75th-percentile daily thresholds, and soil component weights retain full precision until output formatting.

## Input Validation and Diagnostics

AgCAAD validates required files and columns, numeric syntax, finite values, physical ranges, crop threshold ordering, score-key coverage, duplicate scores, and completeness across overlapping soil and climate data. Invalid input stops the run with the failing stage and, when applicable, the filename, row, column, and offending value. Crop/township pairs wholly outside either the soil or climate coverage are reported as a coverage notice and omitted; partially populated overlapping pairs are treated as errors.

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

## Suitability Classes

| Score range | Rating |
| --- | --- |
| `< 0.5` | Unsuitable |
| `0.5-1.49` | Slightly Suitable |
| `1.5-2.49` | Moderately Suitable |
| `2.5-3.49` | Suitable |
| `>= 3.5` | Highly Suitable |

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

Build optimized binaries for all supported platforms:

```powershell
$targets = @('x86_64-windows','aarch64-windows','x86_64-linux','aarch64-linux','x86_64-macos','aarch64-macos')
foreach ($target in $targets) {
    zig build "-Dtarget=$target" -Doptimize=ReleaseFast -p "dst\$target"
}
```

The resulting binaries are written under `dst/<target>/bin/`.

Run tests:

```powershell
zig build test
```

Run from source:

```powershell
zig build run -- --input <input-root> --output <output-root> --threads auto
```
