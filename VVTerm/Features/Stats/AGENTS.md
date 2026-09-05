# Stats

- Own server metrics collection and presentation here.
- Keep `UI/ServerStatsView.swift` a thin root for injected inputs, app/storage state, sheet triggers, and composition. Do not add metric cards, charts, details, or collector operations there.
- Keep collection lifecycle, visibility handling, retry overlay, and collector action closures in `UI/Dashboard/ServerStatsDashboard.swift`.
- Keep block ordering, style selection, preview composition, and layout in `UI/Dashboard/StatsBlocksContent.swift`, `StatsDashboardCards.swift`, and `ClassicStatsContent.swift`.
- Put reusable cards, charts, gauges, and meters in `UI/Components`; put detail sheets and rows in `UI/Details`.
- Keep platform sheet chrome and close/search presentation in `UI/Details/DetailPresentation.swift` and its iOS/macOS files. Product UI types keep neutral names.
- Read [shared UI rules](../../Core/UI/AGENTS.md) for platform splits and presentation.
