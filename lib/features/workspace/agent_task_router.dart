enum WorkspaceAgentTaskType {
  codeEdit,
  codeExplain,
  codeSearch,
  workspaceIndex,
  unknown,
}

class AgentTaskRouter {
  WorkspaceAgentTaskType route(String prompt) {
    final normalized = prompt.toLowerCase();
    if (_containsAny(normalized, const <String>['edit', 'refactor', 'fix'])) {
      return WorkspaceAgentTaskType.codeEdit;
    }
    if (_containsAny(normalized, const <String>['explain', 'why', 'how'])) {
      return WorkspaceAgentTaskType.codeExplain;
    }
    if (_containsAny(normalized, const <String>['find', 'search', 'where'])) {
      return WorkspaceAgentTaskType.codeSearch;
    }
    if (_containsAny(normalized, const <String>['index', 'workspace', 'project scan'])) {
      return WorkspaceAgentTaskType.workspaceIndex;
    }
    return WorkspaceAgentTaskType.unknown;
  }

  bool _containsAny(String input, List<String> tokens) {
    for (final token in tokens) {
      if (input.contains(token)) return true;
    }
    return false;
  }
}

