import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import 'analysis_status.dart';

const finishedStates = {
  'resolved',
  'no_fault_found',
  'inconclusive',
  'cancelled',
};
bool sessionFinished(dynamic state) => finishedStates.contains(state);
Color sessionTone(dynamic state) => switch (state) {
  'resolved' || 'no_fault_found' => const Color(0xFF6CE5BC),
  'analyzing' => const Color(0xFF82B9FF),
  'inconclusive' || 'cancelled' => const Color(0xFFAAB7C4),
  _ => const Color(0xFFFFCA79),
};
IconData sessionIcon(dynamic state) => switch (state) {
  'resolved' || 'no_fault_found' => Icons.task_alt,
  'analyzing' => Icons.hourglass_top,
  'awaiting_measurement' || 'verifying' => Icons.speed_outlined,
  'awaiting_confirmation' => Icons.fact_check_outlined,
  'awaiting_evidence' => Icons.add_photo_alternate_outlined,
  'awaiting_functional_check' => Icons.checklist,
  'awaiting_intervention' => Icons.build_outlined,
  'inconclusive' => Icons.help_outline,
  'cancelled' => Icons.stop_circle_outlined,
  _ => Icons.play_circle_outline,
};
String sessionTitleKey(dynamic state) => switch (state) {
  'resolved' => 'finishedVerified',
  'no_fault_found' => 'finishedNoFault',
  'inconclusive' => 'finishedInconclusive',
  'cancelled' => 'finishedWithoutVerification',
  'analyzing' => 'analyzing',
  'awaiting_measurement' => 'yourTurnMeasurement',
  'awaiting_confirmation' => 'yourTurnConnection',
  'awaiting_evidence' => 'yourTurnPhoto',
  'awaiting_intervention' => 'yourTurnIntervention',
  'awaiting_functional_check' => 'baselineCheckNeeded',
  'verifying' => 'yourTurnVerification',
  _ => 'prepareInvestigation',
};
String sessionSummaryKey(dynamic state) => switch (state) {
  'resolved' => 'finishedVerifiedHelp',
  'no_fault_found' => 'finishedNoFaultHelp',
  'inconclusive' => 'finishedInconclusiveHelp',
  'cancelled' => 'finishedWithoutVerificationHelp',
  'analyzing' => 'analysisProgressNotice',
  'awaiting_measurement' => 'waitingMeasurementHelp',
  'awaiting_confirmation' => 'waitingConnectionHelp',
  'awaiting_evidence' => 'waitingPhotoHelp',
  'awaiting_intervention' => 'waitingInterventionHelp',
  'awaiting_functional_check' => 'baselineCheckHelp',
  'verifying' => 'verificationGuideHelp',
  _ => 'preparationGuideHelp',
};

class SessionGuidance extends StatelessWidget {
  final Map<String, dynamic> session;
  final bool busy, analyzing;
  final VoidCallback onSpec,
      onEvidence,
      onAnalyze,
      onConfirm,
      onManual,
      onBridge,
      onIntervention,
      onFunctional,
      onVerify,
      onBaseline,
      onReport,
      onNew;
  const SessionGuidance({
    super.key,
    required this.session,
    required this.busy,
    this.analyzing = false,
    required this.onSpec,
    required this.onEvidence,
    required this.onAnalyze,
    required this.onConfirm,
    required this.onManual,
    required this.onBridge,
    required this.onIntervention,
    required this.onFunctional,
    required this.onVerify,
    required this.onBaseline,
    required this.onReport,
    required this.onNew,
  });
  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    String tr(String key) => strings.t(key);
    final state = session['state'];
    final terminal = sessionFinished(state);
    final editable = session['can_edit'] == true;
    final enabled = editable && !busy;
    final plan = session['pending_test'] as Map? ?? {};
    final completion = session['completion'] as Map? ?? {};
    final checks = completion['checks'] as List? ?? [];
    final missing = completion['missing_points'] as List? ?? [];
    final baseline = completion['baseline_available'] == true;
    final functional = completion['functional_check'] as Map?;
    final verifications = session['verifications'] as List? ?? [];
    final verification = verifications.isEmpty
        ? null
        : verifications.last['data'] as Map?;
    final jobs = session['jobs'] as List? ?? [];
    final activeJobs = jobs
        .where(
          (j) =>
              j['kind'] == 'analysis' &&
              ['pending', 'running'].contains(j['status']),
        )
        .toList();
    final job = activeJobs.isEmpty ? null : activeJobs.last;
    final finalizing = jobs.any(
      (j) =>
          j['kind'] == 'verification' &&
          ['pending', 'running'].contains(j['status']),
    );
    final tone = sessionTone(state);
    final stage = terminal
        ? 3
        : ['draft', 'ready'].contains(state) &&
              (session['analysis_steps'] ?? 0) == 0
        ? 0
        : [
            'analyzing',
            'awaiting_evidence',
            'awaiting_confirmation',
            'ready',
          ].contains(state)
        ? 1
        : 2;
    final buttons = <Widget>[];
    void button(
      String key,
      VoidCallback callback,
      IconData icon, {
      bool allow = true,
      bool filled = true,
    }) {
      if (!editable) return;
      buttons.add(
        filled
            ? FilledButton.icon(
                onPressed: enabled && allow ? callback : null,
                icon: Icon(icon, size: 19),
                label: Text(tr(key)),
              )
            : OutlinedButton.icon(
                onPressed: enabled && allow ? callback : null,
                icon: Icon(icon, size: 19),
                label: Text(tr(key)),
              ),
      );
    }

    if (!analyzing && !finalizing) {
      if (state == 'draft' || state == 'ready') {
        if ((session['spec_version'] ?? 0) == 0) {
          button('confirmSchematic', onSpec, Icons.account_tree_outlined);
        } else {
          button('analyzeEvidence', onAnalyze, Icons.auto_awesome);
          button(
            'attachImage',
            onEvidence,
            Icons.add_a_photo_outlined,
            filled: false,
          );
        }
      } else if (state == 'awaiting_evidence') {
        button('attachRequestedView', onEvidence, Icons.add_a_photo_outlined);
      } else if (state == 'awaiting_confirmation') {
        button('confirmConnection', onConfirm, Icons.fact_check_outlined);
      } else if (state == 'awaiting_measurement' || state == 'verifying') {
        if (state == 'awaiting_measurement' ||
            missing.isNotEmpty ||
            checks.isEmpty) {
          button('recordMeasurement', onManual, Icons.speed_outlined);
          button('readUsingBridge', onBridge, Icons.usb, filled: false);
        } else if (functional == null) {
          button(
            'recordFunctionalTest',
            onFunctional,
            Icons.fact_check_outlined,
          );
          button(
            'recordMeasurement',
            onManual,
            Icons.speed_outlined,
            filled: false,
          );
        } else {
          button(
            'finishVerification',
            onVerify,
            Icons.task_alt,
            allow: completion['can_verify'] == true,
          );
          button(
            'recordFunctionalTest',
            onFunctional,
            Icons.edit_outlined,
            filled: false,
          );
        }
      } else if (state == 'awaiting_intervention') {
        button(
          'recordCompletedIntervention',
          onIntervention,
          Icons.build_outlined,
        );
      } else if (state == 'awaiting_functional_check' || baseline) {
        button('checkFunctionAndFinish', onBaseline, Icons.checklist);
      }
    }
    if (terminal) {
      buttons.add(
        OutlinedButton.icon(
          onPressed: busy ? null : onReport,
          icon: const Icon(Icons.article_outlined),
          label: Text(tr('readableReport')),
        ),
      );
      button('startFollowUpSession', onNew, Icons.add, filled: false);
    }
    return Container(
      key: const ValueKey('session-guidance'),
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF151F26),
        border: Border.all(color: tone.withValues(alpha: .55)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              for (var i = 0; i < 4; i++)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: (i == stage ? tone : Colors.white).withValues(
                      alpha: i == stage ? .13 : .025,
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${i < stage ? '✓' : i + 1}  ${tr(['guidePrepare', 'guideAnalyze', 'guideCheck', 'guideResult'][i])}',
                    style: TextStyle(
                      fontSize: 12,
                      color: i == stage ? tone : const Color(0xFF91A2AE),
                      fontWeight: i == stage ? FontWeight.w700 : null,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(sessionIcon(state), color: tone, size: 27),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(sessionTitleKey(state)),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      tr(sessionSummaryKey(state)),
                      style: const TextStyle(
                        color: Color(0xFFB9C6CF),
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!terminal && !analyzing && plan['instruction'] != null) ...[
            const SizedBox(height: 16),
            Text(
              (plan['translations']
                      as Map?)?[strings.language]?['instruction'] ??
                  plan['instruction'],
              style: const TextStyle(fontSize: 16, height: 1.6),
            ),
          ],
          if (state == 'awaiting_measurement' && plan['point_id'] != null) ...[
            const SizedBox(height: 12),
            Text(
              strings.t('requestedPointGuide', {'point': plan['point_id']}),
              style: TextStyle(color: tone, fontWeight: FontWeight.w600),
            ),
          ],
          if (finalizing) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(tr('finalizingOutcome')),
          ],
          if (analyzing) ...[
            const SizedBox(height: 16),
            AnalysisStatusBanner(
              status: job?['status'] ?? 'submitting',
              attempts: (job?['attempts'] as num?)?.toInt() ?? 0,
            ),
          ],
          if (state == 'verifying' && checks.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              tr('verificationChecklist'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            for (final check in checks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Icon(
                      check['measurement_id'] == null
                          ? Icons.radio_button_unchecked
                          : check['passed'] == true
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 19,
                      color: check['passed'] == true
                          ? const Color(0xFF6CE5BC)
                          : const Color(0xFFFFCA79),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        '${check['point_id']} · ${check['label'] ?? ''} — ${check['value'] == null ? tr('readingStillNeeded') : '${(check['value'] as num).toStringAsFixed(3)} V'}',
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                '${functional == null ? '○' : '✓'}  ${tr('recordFunctionalTest')}',
              ),
            ),
            if (functional != null && functional['passed'] != true)
              Text(
                tr('failedFunctionalWillNotResolve'),
                style: const TextStyle(color: Color(0xFFFFCA79)),
              ),
          ],
          if (state == 'awaiting_functional_check' || baseline) ...[
            const SizedBox(height: 12),
            Text(
              session['specification']?['functional_description'] ?? '',
              style: const TextStyle(color: Color(0xFFB9C6CF)),
            ),
          ],
          if (terminal &&
              verification?['physical_verification'] != true &&
              state != 'no_fault_found') ...[
            const SizedBox(height: 10),
            Text(
              tr('thisDoesNotEstablishFullPhysicalVerification'),
              style: const TextStyle(color: Color(0xFFFFCA79)),
            ),
          ],
          if (terminal &&
              verification?['verification_basis'] == 'simulated') ...[
            const SizedBox(height: 8),
            Text(
              tr('simulatedCompletionNotice'),
              style: const TextStyle(color: Color(0xFFFFCA79)),
            ),
          ],
          if (!editable && !terminal) ...[
            const SizedBox(height: 12),
            Text(tr('readerWaitingOwner')),
          ],
          if (buttons.isNotEmpty) ...[
            const SizedBox(height: 20),
            Wrap(spacing: 10, runSpacing: 10, children: buttons),
          ],
        ],
      ),
    );
  }
}
