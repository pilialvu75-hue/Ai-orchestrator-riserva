import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';

class PersonalDataPage extends StatefulWidget {
  const PersonalDataPage({super.key});

  @override
  State<PersonalDataPage> createState() => _PersonalDataPageState();
}

class _PersonalDataPageState extends State<PersonalDataPage> {
  final _nameController = TextEditingController();
  final _birthDateController = TextEditingController();
  final _profileController = TextEditingController();

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _birthDateController.dispose();
    _profileController.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _nameController.text = prefs.getString(AppConstants.prefUserName) ?? '';
    _birthDateController.text =
        prefs.getString(AppConstants.prefUserBirthDate) ?? '';
    _profileController.text =
        prefs.getString(AppConstants.prefUserProfileData) ?? '';
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        AppConstants.prefUserName, _nameController.text.trim());
    await prefs.setString(
        AppConstants.prefUserBirthDate, _birthDateController.text.trim());
    await prefs.setString(
        AppConstants.prefUserProfileData, _profileController.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.t('settings_saved'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          l10n.t('personal_data_optional'),
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w500),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF8AB4F8)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
              children: [
                TextField(
                  controller: _nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(labelText: l10n.t('name')),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _birthDateController,
                  style: const TextStyle(color: Colors.white),
                  decoration:
                      InputDecoration(labelText: l10n.t('date_of_birth')),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _profileController,
                  maxLines: 4,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: l10n.t('profile_data_optional'),
                  ),
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _save,
                    child: Text(l10n.t('save')),
                  ),
                ),
              ],
            ),
    );
  }
}
