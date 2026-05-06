import Foundation
import Testing
import Yams

struct LiteLLMConfigSanityTests {
    @Test func defaultConfigParses() throws {
        guard let url = Bundle.main.url(
            forResource: "default-litellm-config",
            withExtension: "yaml"
        ) else {
            Issue.record("default-litellm-config.yaml is not in the host app bundle")
            return
        }

        let yamlText = try String(contentsOf: url, encoding: .utf8)
        let parsed = try Yams.load(yaml: yamlText)
        guard let root = parsed as? [String: Any] else {
            Issue.record("YAML root is not a dictionary; got \(type(of: parsed as Any))")
            return
        }

        #expect(root["model_list"] != nil, "missing top-level 'model_list'")
        #expect(root["router_settings"] != nil, "missing top-level 'router_settings'")
        #expect(root["litellm_settings"] != nil, "missing top-level 'litellm_settings'")

        guard let modelList = root["model_list"] as? [[String: Any]] else {
            Issue.record("model_list is not an array of dictionaries")
            return
        }
        let aliases = modelList.compactMap { $0["model_name"] as? String }
        for alias in ["summary-fast", "summary-deep", "mom-default"] {
            #expect(aliases.contains(alias), "missing alias: \(alias)")
        }
    }
}
