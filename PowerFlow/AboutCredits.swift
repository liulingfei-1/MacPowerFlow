import AppKit

@MainActor
enum AboutCredits {
    private struct Project {
        let name: String
        let url: URL
    }

    private static let repositoryURL = URL(
        string: "https://github.com/liulingfei-1/MacPowerFlow"
    )!
    private static let releasesURL = URL(
        string: "https://github.com/liulingfei-1/MacPowerFlow/releases"
    )!

    private static let projects = [
        Project(name: "macmon", url: URL(string: "https://github.com/vladkens/macmon")!),
        Project(name: "Stats", url: URL(string: "https://github.com/exelban/stats")!),
        Project(
            name: "macpow",
            url: URL(string: "https://github.com/k06a/macpow")!
        ),
        Project(
            name: "MacMonitor",
            url: URL(string: "https://github.com/ryyansafar/MacMonitor")!
        ),
        Project(
            name: "Powerflow",
            url: URL(string: "https://github.com/lzt1008/powerflow")!
        ),
        Project(
            name: "WhatBattery",
            url: URL(string: "https://github.com/darrylmorley/whatbattery")!
        ),
        Project(
            name: "mactop",
            url: URL(string: "https://github.com/metaspartan/mactop")!
        ),
    ]

    static func make() -> NSAttributedString {
        let result = NSMutableAttributedString()

        appendLink("GitHub 仓库", url: repositoryURL, to: result)
        append(
            "   ·   ",
            to: result,
            font: .systemFont(ofSize: 11),
            color: .tertiaryLabelColor
        )
        appendLink("版本发布", url: releasesURL, to: result)
        append(
            "\n",
            to: result,
            font: .systemFont(ofSize: 11),
            color: .labelColor,
            paragraphSpacing: 2
        )
        append(
            "基于 Apple 系统框架 · 无第三方运行时依赖\n\n",
            to: result,
            font: .systemFont(ofSize: 10),
            color: .secondaryLabelColor,
            paragraphSpacing: 3
        )

        append(
            "开源与致谢\n",
            to: result,
            font: .systemFont(ofSize: 12.5, weight: .semibold),
            color: .labelColor,
            paragraphSpacing: 3
        )
        append(
            "以下项目用于采样、兼容与能量流参考或改编：\n",
            to: result,
            font: .systemFont(ofSize: 10.5),
            color: .secondaryLabelColor,
            paragraphSpacing: 2
        )

        appendProjectLinks(Array(projects.prefix(3)), to: result)
        append(
            "\n",
            to: result,
            font: .systemFont(ofSize: 10.5),
            color: .secondaryLabelColor
        )
        appendProjectLinks(Array(projects.suffix(2)), to: result)

        append(
            "\n",
            to: result,
            font: .systemFont(ofSize: 10),
            color: .labelColor,
            paragraphSpacing: 3
        )
        if let noticesURL = Bundle.main.url(
            forResource: "THIRD_PARTY_NOTICES",
            withExtension: "md"
        ) {
            appendLink("完整第三方许可", url: noticesURL, to: result)
        }
        append(
            "   ·   ",
            to: result,
            font: .systemFont(ofSize: 10.5),
            color: .tertiaryLabelColor
        )
        if let licenseURL = Bundle.main.url(
            forResource: "LICENSE",
            withExtension: "txt"
        ) {
            appendLink("本项目 MIT 许可", url: licenseURL, to: result)
        }

        return result
    }

    private static func appendProjectLinks(
        _ projects: [Project],
        to result: NSMutableAttributedString
    ) {
        for (index, project) in projects.enumerated() {
            appendLink(project.name, url: project.url, to: result)
            if index < projects.count - 1 {
                append(
                    "   ·   ",
                    to: result,
                    font: .systemFont(ofSize: 10.5),
                    color: .tertiaryLabelColor
                )
            }
        }
    }

    private static func appendLink(
        _ text: String,
        url: URL,
        to result: NSMutableAttributedString
    ) {
        append(
            text,
            to: result,
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: .linkColor,
            link: url,
            paragraphSpacing: 0
        )
    }

    private static func append(
        _ text: String,
        to result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor,
        link: URL? = nil,
        paragraphSpacing: CGFloat = 0
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 1.5
        paragraph.paragraphSpacing = paragraphSpacing

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if let link {
            attributes[.link] = link
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        result.append(NSAttributedString(string: text, attributes: attributes))
    }
}
