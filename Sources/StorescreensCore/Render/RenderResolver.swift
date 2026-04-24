import Foundation

/// Resolves a `RenderConfig` for a specific slide by merging the top-level
/// defaults with any slide-specific overrides. Every field is merged
/// individually: a slide override for `chrome.stroke_color` replaces only
/// that field, leaving the rest inherited from the defaults.
///
/// Callers pass screenshot names as they appear in the manifest (e.g.
/// "01_Home"); unknown names simply inherit the defaults unchanged.
package enum RenderResolver {

    /// If `config.template` names a known template, return a copy where the
    /// template's values fill in any gaps not set by the user. User-supplied
    /// fields always win. Returns the original config unchanged when no
    /// template is set or when the name doesn't match a built-in.
    ///
    /// Called once by `RenderPipeline.init` so downstream resolve calls see
    /// the fully-baked defaults without having to know about templates.
    package static func applyTemplate(_ config: RenderConfig) -> RenderConfig {
        guard let name = config.template, !name.isEmpty,
              let template = RenderTemplate.find(name) else {
            return config
        }
        let t = template.config
        return RenderConfig(
            enabled: config.enabled ?? t.enabled,
            outputDir: config.outputDir ?? t.outputDir,
            template: config.template,
            background: mergeBackground(base: t.background, override: config.background),
            scrim: mergeScrim(base: t.scrim, override: config.scrim),
            logo: mergeLogo(base: t.logo, override: config.logo),
            caption: mergeCaption(base: t.caption, override: config.caption),
            chrome: mergeChrome(base: t.chrome, override: config.chrome),
            slides: config.slides ?? t.slides
        )
    }

    /// Resolved caption for a slide. Combines slide-level text + highlights
    /// with role styles from the defaults (optionally overridden per slide).
    package struct ResolvedCaption: Sendable {
        package let title: CaptionText?
        package let subtitle: CaptionText?
        package let highlights: [CaptionHighlight]
        package let titleStyle: CaptionRole?
        package let subtitleStyle: CaptionRole?
        package let spacingPct: Double?
        package let minHeightPct: Double?
        package let paddingPct: Double?
        package let verticalAlign: VerticalAlign?
        package let nudge: NudgeConfig?
    }

    package static func resolvedBackground(
        config: RenderConfig,
        slideName: String
    ) -> BackgroundConfig? {
        let base = config.background
        let override = config.slides?[slideName]?.background
        return mergeBackground(base: base, override: override)
    }

    package static func resolvedScrim(
        config: RenderConfig,
        slideName: String
    ) -> ScrimConfig? {
        let base = config.scrim
        let override = config.slides?[slideName]?.scrim
        return mergeScrim(base: base, override: override)
    }

    package static func resolvedLogo(
        config: RenderConfig,
        slideName: String
    ) -> LogoConfig? {
        let base = config.logo
        let override = config.slides?[slideName]?.logo
        return mergeLogo(base: base, override: override)
    }

    package static func resolvedChrome(
        config: RenderConfig,
        slideName: String
    ) -> ChromeConfig? {
        let base = config.chrome
        let override = config.slides?[slideName]?.chrome
        return mergeChrome(base: base, override: override)
    }

    package static func resolvedCaption(
        config: RenderConfig,
        slideName: String,
        locale: String? = nil
    ) -> ResolvedCaption? {
        let defaults = config.caption
        let slideOverride = config.slides?[slideName]
        let slide = slideOverride?.caption

        // If both are nil and we'd produce nothing meaningful, skip rendering captions entirely.
        if defaults == nil && slide == nil && slideOverride?.captionLocales == nil { return nil }

        // Resolve title: per-locale override takes precedence over the
        // slide's fallback caption.title.
        let localeTitle: CaptionText? = {
            guard let locale, let map = slideOverride?.captionLocales else { return nil }
            return map[locale]
        }()
        let title = localeTitle ?? slide?.title
        let subtitle = slide?.subtitle

        // Style merging: slide-level style overrides win field-by-field over defaults.
        let titleStyle = mergeRole(base: defaults?.title, override: slide?.titleStyle)
        let subtitleStyle = mergeRole(base: defaults?.subtitle, override: slide?.subtitleStyle)

        return ResolvedCaption(
            title: title,
            subtitle: subtitle,
            highlights: slide?.highlights ?? [],
            titleStyle: titleStyle,
            subtitleStyle: subtitleStyle,
            spacingPct: defaults?.spacingPct,
            minHeightPct: defaults?.minHeightPct,
            paddingPct: defaults?.paddingPct,
            verticalAlign: defaults?.verticalAlign,
            nudge: defaults?.nudge
        )
    }

    // MARK: - Mergers

    static func mergeBackground(base: BackgroundConfig?, override: BackgroundConfig?) -> BackgroundConfig? {
        guard override != nil || base != nil else { return nil }
        return BackgroundConfig(
            image: override?.image ?? base?.image,
            color: override?.color ?? base?.color,
            align: override?.align ?? base?.align,
            fit: override?.fit ?? base?.fit,
            pattern: mergePattern(base: base?.pattern, override: override?.pattern)
        )
    }

    static func mergePattern(base: PatternConfig?, override: PatternConfig?) -> PatternConfig? {
        guard override != nil || base != nil else { return nil }
        // `pattern` is required on PatternConfig (no nullable enum), so fall
        // through to `.topographic` only as an unreachable failsafe — either
        // side present means its pattern wins by position.
        let chosen = override?.pattern ?? base?.pattern ?? .topographic
        return PatternConfig(
            pattern: chosen,
            color: override?.color ?? base?.color,
            opacity: override?.opacity ?? base?.opacity
        )
    }

    static func mergeCaption(base: CaptionConfig?, override: CaptionConfig?) -> CaptionConfig? {
        guard override != nil || base != nil else { return nil }
        return CaptionConfig(
            title: mergeRole(base: base?.title, override: override?.title),
            subtitle: mergeRole(base: base?.subtitle, override: override?.subtitle),
            spacingPct: override?.spacingPct ?? base?.spacingPct,
            minHeightPct: override?.minHeightPct ?? base?.minHeightPct,
            paddingPct: override?.paddingPct ?? base?.paddingPct,
            verticalAlign: override?.verticalAlign ?? base?.verticalAlign,
            nudge: mergeNudge(base: base?.nudge, override: override?.nudge)
        )
    }

    static func mergeScrim(base: ScrimConfig?, override: ScrimConfig?) -> ScrimConfig? {
        guard override != nil || base != nil else { return nil }
        return ScrimConfig(
            color: override?.color ?? base?.color,
            opacity: override?.opacity ?? base?.opacity,
            gradient: mergeScrimGradient(base: base?.gradient, override: override?.gradient)
        )
    }

    static func mergeScrimGradient(base: ScrimGradient?, override: ScrimGradient?) -> ScrimGradient? {
        guard override != nil || base != nil else { return nil }
        return ScrimGradient(
            topOpacity: override?.topOpacity ?? base?.topOpacity,
            bottomOpacity: override?.bottomOpacity ?? base?.bottomOpacity
        )
    }

    static func mergeLogo(base: LogoConfig?, override: LogoConfig?) -> LogoConfig? {
        guard override != nil || base != nil else { return nil }
        return LogoConfig(
            path: override?.path ?? base?.path,
            placement: override?.placement ?? base?.placement,
            maxHeightPct: override?.maxHeightPct ?? base?.maxHeightPct,
            topPaddingPct: override?.topPaddingPct ?? base?.topPaddingPct,
            nudge: mergeNudge(base: base?.nudge, override: override?.nudge)
        )
    }

    static func mergeNudge(base: NudgeConfig?, override: NudgeConfig?) -> NudgeConfig? {
        guard override != nil || base != nil else { return nil }
        return NudgeConfig(
            xPct: override?.xPct ?? base?.xPct,
            yPct: override?.yPct ?? base?.yPct
        )
    }

    static func mergeChrome(base: ChromeConfig?, override: ChromeConfig?) -> ChromeConfig? {
        guard override != nil || base != nil else { return nil }
        return ChromeConfig(
            style: override?.style ?? base?.style,
            strokeColor: override?.strokeColor ?? base?.strokeColor,
            strokeWidth: override?.strokeWidth ?? base?.strokeWidth,
            cornerRadius: override?.cornerRadius ?? base?.cornerRadius,
            shadow: override?.shadow ?? base?.shadow,
            paddingPct: override?.paddingPct ?? base?.paddingPct,
            modelPreference: override?.modelPreference ?? base?.modelPreference,
            colorwayPreference: override?.colorwayPreference ?? base?.colorwayPreference
        )
    }

    static func mergeRole(base: CaptionRole?, override: CaptionRole?) -> CaptionRole? {
        guard override != nil || base != nil else { return nil }
        return CaptionRole(
            font: override?.font ?? base?.font,
            weight: override?.weight ?? base?.weight,
            italic: override?.italic ?? base?.italic,
            fontSizePct: override?.fontSizePct ?? base?.fontSizePct,
            minFontSizePct: override?.minFontSizePct ?? base?.minFontSizePct,
            color: override?.color ?? base?.color,
            align: override?.align ?? base?.align
        )
    }
}
