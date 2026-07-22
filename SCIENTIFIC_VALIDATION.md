# Scientific validation

AgCAAD is implemented against two complementary references:

1. *Appendix D: Model to Determine Suitability of a Region for a Large Number of Crops* (2004), which defines the scientific equations and rating figures.
2. The archived AgCAAD 2020 production implementation and its 1981-2010 Alberta intermediate outputs, which resolve implementation details that are visually ambiguous in the scanned figures.

The automated tests use small, embedded reference values derived from those sources. They do not read the archive, the PDF, or `examples.zip` during `zig build test`.

## Confirmed rules

- Hourly temperature uses scores 0, 3, 5, 3, 0. The prose reference to a 0-4 temperature scale is a typo; Equation 2 explicitly assigns 5 to the optimum interval.
- The final climatic term uses an exact cube root. The printed exponent `0.3` denotes that cube root rather than the decimal exponent 0.3.
- The overall score is reported to one decimal before applying the published 0.5, 1.5, 2.5, and 3.5 rating boundaries, matching the production model.
- Wide and narrow precipitation rules, including all wet-side limits, match the Appendix D figure and the archived `agcaad_2020_precip_scores.py`. Tests cover both sides of every integer-reachable boundary.
- Winter cold tolerance advances one class per degree above the critical minimum and becomes highly suitable above critical + 3 C.
- Annual growing days are the continuous intersection of the frost-free interval and the interval whose daily maximum exceeds the crop absolute minimum. Winter annuals receive the specified growing-day score and use the specified planting, harvest, and dormancy probability thresholds for temperature scoring.
- Soil pH is first aggregated to a township map-unit property using Appendix D Equation 1, then classified for each crop. No component or contribution is rounded before aggregation.
- Soil texture and drainage are categorical properties. Their suitability scores are area-weighted using the authoritative crop-by-class lookup tables, as in the production implementation. Averaging categorical codes would have no scientifically defined meaning.
- Every township's soil component area fractions must sum to 1.0 within 0.001. An incomplete or over-complete map unit stops with the file, township, observed sum, and expected tolerance.

## Validation limits

The available crop texture requirements use Alberta categorical texture groups rather than a numeric modified texture triangle, and drainage uses categorical classes. Consequently, the model preserves the validated lookup-table method for those properties. A future switch to property-first numeric classification would require an authoritative texture-triangle algorithm and an authoritative numeric drainage scale; neither should be inferred from category labels.

The full example dataset is an integration fixture used manually before releases. Compatibility means the input schema validates and the complete run succeeds; corrected scientific rules can intentionally change scores relative to older generated outputs.
