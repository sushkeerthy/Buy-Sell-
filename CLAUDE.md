# 10XBA Buy/Sell — Semantic Model

## What This Is
Microsoft Fabric SQL Lakehouse semantic model for the 10XBA Buy/Sell business.
Powers Power BI reports across 11 HubSpot deal pipelines.

## Key Data Sources
- `[IT_Data_Gateway].[HubSpot].[bronze_DealStages]` — stage definitions (abbreviated pipeline labels)
- `[IT_Data_Gateway].[HubSpot].[bronze_DealPipelines]` — pipeline-level display order
- `[IT_Data_Gateway].[HubSpot].[silver_Deals]` — deal records, joins on `DealStage = stage_id`

## Critical Gotcha
`bronze_DealStages` stores **abbreviated** pipeline labels (`10XBS | Buy Side DE`), not full names.
Any WHERE clause filtering by pipeline must use the abbreviated form.

## Main View
`vw_BuySellPipelineMatrix` — see `vw_BuySellPipelineMatrix_context.md` for full context:
- CTE-based: `bronze_trimmed` (filter + label expansion) → `stage_map` (all stage logic once)
- 3-part UNION: real deals | placeholder rows | CV Sales Pipeline closed-won
- Adding a new HubSpot stage: add one WHEN line in `stage_map`. The ELSE fallback handles it automatically until then.
- `StageGroupOrder` = cross-pipeline column sort (business logic, not in HubSpot)
- `StageOrder` = `display_order` from bronze_DealStages (per-pipeline, not cross-pipeline comparable)
- `PipelineOrder` = `bronze_DealPipelines.display_order` (live, not hardcoded)
