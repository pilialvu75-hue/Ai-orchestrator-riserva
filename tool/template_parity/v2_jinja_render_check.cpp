// Synthetic rendering only: no model loading or inference.
// Compile against ggml-org/llama.cpp d8d92973c, not the checkout submodule.
#include <iostream>
#include <string>
#include "json.h"
#include "jinja/runtime.h"
#include "jinja/parser.h"
#include "jinja/lexer.h"

int main() {
    std::string line;
    while (std::getline(std::cin, line)) {
        auto fixture = common_json::parse(line);
        auto source = fixture.at("template").get<std::string>();
        auto vars = fixture.at("variables");
        jinja::lexer lexer;
        auto ast = jinja::parse_from_tokens(lexer.tokenize(source));
        jinja::context ctx(source);
        jinja::global_from_json(ctx, vars, true);
        const auto bos = vars.at("bos_token").get<std::string>();
        const auto eos = vars.at("eos_token").get<std::string>();
        ctx.set_val("bos_token", jinja::mk_val<jinja::value_string>(bos));
        ctx.set_val("eos_token", jinja::mk_val<jinja::value_string>(eos));
        jinja::runtime runtime(ctx);
        auto parts = runtime.gather_string_parts(runtime.execute(ast));
        std::string rendered, server_text;
        bool first = true;
        for (const auto &part : parts->as_string().parts) {
            rendered += part.val;
            std::string text = part.val;
            if (first && !part.is_input && text.rfind(bos, 0) == 0) {
                text.erase(0, bos.size());
            }
            server_text += text;
            first = false;
        }
        const auto expected = fixture.at("expected_without_bos").get<std::string>();
        common_json result = {
            {"id", fixture.at("id")},
            {"raw_render", rendered},
            {"add_bos_normalized", server_text},
            {"matches_expected", server_text == expected}
        };
        std::cout << result.dump() << std::endl;
        if (server_text != expected) return 1;
    }
}