import ArgumentParser
import Foundation
import StorescreensCore

@main
struct StoreScreensCLI: AsyncParsableCommand {
    // Force line-buffered stdout so progress lines stream in real-time
    // even when output is piped (e.g. to another process or file).
    static let _lineBuffered: Void = {
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
    }()

    static let configuration = CommandConfiguration(
        commandName: "storescreens",
        abstract: "Capture App Store screenshots across iOS simulators and macOS.",
        version: storescreensVersion,
        subcommands: [
            // Capture / render / setup
            ListCommand.self, InitCommand.self, SetupCommand.self, CaptureCommand.self,
            CheckCommand.self, ScreenshotCommand.self, BezelsCommand.self, RenderCommand.self,
            SearchPreviewCommand.self, TemplatesCommand.self, ThemesCommand.self,
            // App Store Connect: submit + binary upload + state
            AuthCommand.self, SubmitCommand.self, MetadataCommand.self, TranslateCommand.self,
            UploadBuildCommand.self,
            StatusCommand.self, ReviewSubmissionsCommand.self, PricingCommand.self,
            // App Store Connect: full API surface (added 2026-05)
            TestFlightCommand.self, InAppPurchaseCommand.self, SubscriptionCommand.self,
            ReviewsCommand.self, ReportsCommand.self, UsersCommand.self, DevPortalCommand.self,
            PreviewsCommand.self, AppClipsCommand.self, CustomProductPagesCommand.self,
            EventsCommand.self, ExperimentsCommand.self, EncryptionDeclCommand.self,
            RoutingCoverageCommand.self,
            // ASC API Wave 2 (added 2026-05): Game Center, Xcode Cloud, EU alt-distribution,
            // Apple Pay + sandbox testers + resource limits + diagnostic sessions
            GameCenterCommand.self, XcodeCloudCommand.self, AltDistributionCommand.self,
            ApplePayCommand.self, SandboxCommand.self, ResourceLimitsCommand.self,
            DiagnosticSessionsCommand.self,
            // ASC API Wave 3 (added 2026-05): general-purpose webhooks, API-native
            // build uploads, accessibility nutrition labels
            WebhooksCommand.self, BuildUploadsCommand.self, AccessibilityDeclarationsCommand.self,
            // ASC API Wave 4 (added 2026-05): Apple's 2025-2026 additions
            BackgroundAssetsCommand.self, VersionReleaseControlCommand.self,
            GameCenterActivitiesCommand.self,
            BetaFeedbackCommand.self, BetaRecruitmentCommand.self,
            BetaAppClipInvocationsCommand.self, IAPOfferCodesCommand.self,
            SubscriptionExtrasCommand.self, ReviewExtrasCommand.self,
            AscExtrasCommand.self,
            // Community: submit your app to storescreens.app's Wall of Apps.
            WallCommand.self,
        ]
    )

    mutating func validate() throws {
        _ = Self._lineBuffered
    }
}
