import 'package:ai_orchestrator/app_factory/workshop/workshop_conversation_contract.dart';

/// Routes a natural-language Workshop conversation into a structured
/// conversational decision.
///
/// This class deliberately does NOT perform LLM inference.
///
/// The LLM (or another future intent classifier) is responsible for
/// understanding the user's natural language. This router is responsible
/// only for turning an already structured intent into the appropriate
/// Workshop response strategy.
///
/// Keeping these responsibilities separate means that:
///
/// - the Workshop UI does not need to know about LLMs;
/// - the WorkshopEngine does not need to parse natural language;
/// - the Assistant Chat is not involved;
/// - the routing rules remain deterministic;
/// - the same intent can later be produced by a local or cloud model.
final class WorkshopConversationRouter {
  const WorkshopConversationRouter();

  /// Converts an interpreted [intent] into a Workshop decision.
  ///
  /// [userMessage] is retained only as conversational metadata. It is not
  /// interpreted by this class.
  WorkshopConversationDecision route(
    WorkshopConversationIntent intent, {
    String? userMessage,
  }) {
    if (intent.requiresClarification) {
      return WorkshopConversationDecision(
        intent: intent,
        strategy: WorkshopResponseStrategy.askClarification,
        userMessage: userMessage,
      );
    }

    switch (intent.mode) {
      case WorkshopInteractionMode.directBuild:
        return WorkshopConversationDecision(
          intent: intent,
          strategy: WorkshopResponseStrategy.buildAndConfirm,
          userMessage: userMessage,
        );

      case WorkshopInteractionMode.collaborativePlanning:
        return WorkshopConversationDecision(
          intent: intent,
          strategy: WorkshopResponseStrategy.presentPlan,
          userMessage: userMessage,
        );

      case WorkshopInteractionMode.continuation:
        return WorkshopConversationDecision(
          intent: intent,
          strategy: WorkshopResponseStrategy.executeNextStep,
          userMessage: userMessage,
        );

      case WorkshopInteractionMode.review:
        return WorkshopConversationDecision(
          intent: intent,
          strategy: WorkshopResponseStrategy.analyseAndReport,
          userMessage: userMessage,
        );

      case WorkshopInteractionMode.modification:
        return WorkshopConversationDecision(
          intent: intent,
          strategy: WorkshopResponseStrategy.executeNextStep,
          userMessage: userMessage,
        );

      case WorkshopInteractionMode.explanation:
        return WorkshopConversationDecision(
          intent: intent,
          strategy: WorkshopResponseStrategy.explainOnly,
          userMessage: userMessage,
        );

      case WorkshopInteractionMode.diagnosis:
        return WorkshopConversationDecision(
          intent: intent,
          strategy: WorkshopResponseStrategy.diagnoseAndPropose,
          userMessage: userMessage,
        );

      case WorkshopInteractionMode.clarification:
        return WorkshopConversationDecision(
          intent: intent,
          strategy: WorkshopResponseStrategy.askClarification,
          userMessage: userMessage,
        );
    }
  }

  /// Convenience method for callers that already have a decision.
  ///
  /// Useful when an external classifier has produced a complete
  /// [WorkshopConversationDecision] and the caller wants to ensure that
  /// clarification decisions are never accidentally executed.
  WorkshopConversationDecision normalize(
    WorkshopConversationDecision decision,
  ) {
    if (decision.intent.requiresClarification &&
        !decision.asksClarification) {
      return WorkshopConversationDecision(
        intent: decision.intent,
        strategy: WorkshopResponseStrategy.askClarification,
        userMessage: decision.userMessage,
      );
    }

    return decision;
  }

  /// Returns the strategy that should be used for an intent without creating
  /// a complete decision object.
  WorkshopResponseStrategy strategyFor(
    WorkshopConversationIntent intent,
  ) {
    return route(intent).strategy;
  }

  /// Whether the given intent is safe to enter into an execution stage.
  ///
  /// This does NOT mean that files may be changed.
  ///
  /// It only means that the conversational layer has enough information
  /// to proceed without first asking the user for clarification.
  bool canProceed(
    WorkshopConversationIntent intent,
  ) {
    return !intent.requiresClarification;
  }

  /// Whether the Workshop should first show a plan to the user.
  bool shouldPresentPlan(
    WorkshopConversationIntent intent,
  ) {
    return strategyFor(intent) ==
        WorkshopResponseStrategy.presentPlan;
  }

  /// Whether the Workshop may start its construction pipeline.
  ///
  /// Actual file modifications remain protected by the later
  /// proposal/diff/approval layers.
  bool shouldStartConstruction(
    WorkshopConversationIntent intent,
  ) {
    final strategy = strategyFor(intent);

    return strategy ==
            WorkshopResponseStrategy.buildAndConfirm ||
        strategy ==
            WorkshopResponseStrategy.executeNextStep ||
        strategy ==
            WorkshopResponseStrategy.diagnoseAndPropose;
  }

  /// Whether the Workshop should return an explanation without changing
  /// project state.
  bool shouldExplainOnly(
    WorkshopConversationIntent intent,
  ) {
    return strategyFor(intent) ==
        WorkshopResponseStrategy.explainOnly;
  }

  /// Whether the Workshop should inspect the project and report findings.
  bool shouldAnalyseAndReport(
    WorkshopConversationIntent intent,
  ) {
    return strategyFor(intent) ==
        WorkshopResponseStrategy.analyseAndReport;
  }

  /// Whether the Workshop should ask the user for more information.
  bool shouldAskClarification(
    WorkshopConversationIntent intent,
  ) {
    return strategyFor(intent) ==
        WorkshopResponseStrategy.askClarification;
  }
}
