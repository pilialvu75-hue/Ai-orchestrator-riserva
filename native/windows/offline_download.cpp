// Local-file-only boundary for the Windows completion helper. Model download
// and WebSearch remain owned by the Dart application, on every platform.
#include "common.h"
#include "download.h"
#include "hf-cache.h"

#include <stdexcept>

namespace {
[[noreturn]] void remote_unavailable() {
    throw std::runtime_error(
        "Windows completion is local-file-only. Import a GGUF in AI-Orchestrator and use -m <path>.");
}
}

std::pair<long, std::vector<char>> common_remote_get_content(
    const std::string &, const common_remote_params &) { remote_unavailable(); }

std::pair<std::string, std::string> common_download_split_repo_tag(const std::string & repo) {
    const auto colon = repo.rfind(':');
    return colon == std::string::npos
        ? std::make_pair(repo, std::string())
        : std::make_pair(repo.substr(0, colon), repo.substr(colon + 1));
}

common_download_model_result common_download_model(
    const common_params_model & model, const common_download_opts &, bool) {
    if (!model.hf_repo.empty() || !model.url.empty()) remote_unavailable();
    common_download_model_result result;
    result.model_path = model.path;
    return result;
}

std::vector<common_cached_model_info> common_list_cached_models() { return {}; }

int common_download_file_single(
    const std::string &, const std::string &, const common_download_opts &, bool) {
    remote_unavailable();
}

std::string common_docker_resolve_model(const std::string &) { remote_unavailable(); }

namespace hf_cache {
hf_files get_repo_files(const std::string &, const std::string &) { remote_unavailable(); }
hf_files get_cached_files(const std::string &) { return {}; }
std::string finalize_file(const hf_file &) { remote_unavailable(); }
void migrate_old_cache_to_hf_cache(const std::string &, bool) {}
}
