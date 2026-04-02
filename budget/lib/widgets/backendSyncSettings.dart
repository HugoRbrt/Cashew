import 'package:budget/struct/backendSyncService.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:flutter/material.dart';

class BackendSyncSettings extends StatefulWidget {
  const BackendSyncSettings({super.key});

  @override
  State<BackendSyncSettings> createState() => _BackendSyncSettingsState();
}

class _BackendSyncSettingsState extends State<BackendSyncSettings> {
  bool _syncing = false;
  String? _lastSync;
  String? _syncResult;
  bool _isConfigured = false;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  void _loadState() {
    _lastSync = sharedPreferences.getString('backendLastSync');
    String? url = sharedPreferences.getString('backendSyncUrl');
    String? key = sharedPreferences.getString('backendSyncApiKey');
    _isConfigured =
        url != null && url.isNotEmpty && key != null && key.isNotEmpty;
  }

  Future<void> _runSync() async {
    BackendSyncService? service = BackendSyncService.fromSettings();
    if (service == null) {
      setState(() {
        _syncResult = 'Backend not configured';
      });
      return;
    }

    setState(() {
      _syncing = true;
      _syncResult = null;
    });

    try {
      SyncResult result = await service.sync();
      setState(() {
        _syncing = false;
        _syncResult = result.toString();
        _lastSync = sharedPreferences.getString('backendLastSync');
      });
    } catch (e) {
      setState(() {
        _syncing = false;
        _syncResult = 'Sync failed: $e';
      });
    }
  }

  void _openConfigDialog() {
    String currentUrl =
        sharedPreferences.getString('backendSyncUrl') ?? '';
    String currentKey =
        sharedPreferences.getString('backendSyncApiKey') ?? '';

    TextEditingController urlController =
        TextEditingController(text: currentUrl);
    TextEditingController keyController =
        TextEditingController(text: currentKey);

    openBottomSheet(
      context,
      PopupFramework(
        title: 'Backend Sync Config',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                controller: urlController,
                decoration: InputDecoration(
                  labelText: 'Backend URL',
                  hintText: 'https://your-backend.com',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: TextField(
                controller: keyController,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: 'your-api-key',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  await BackendSyncService.saveSettings(
                    urlController.text.trim(),
                    keyController.text.trim(),
                  );
                  setState(() {
                    _loadState();
                  });
                  Navigator.of(context).pop();
                },
                child: Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatLastSync() {
    if (_lastSync == null) return 'Never';
    try {
      DateTime dt = DateTime.parse(_lastSync!);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return _lastSync!;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsContainer(
          title: 'Backend Sync Config',
          description: _isConfigured
              ? 'Connected'
              : 'Not configured — tap to set up',
          icon: Icons.settings_ethernet_rounded,
          onTap: _openConfigDialog,
        ),
        SettingsContainer(
          title: 'Sync Now',
          description: _syncing
              ? 'Syncing...'
              : _syncResult ?? 'Last sync: ${_formatLastSync()}',
          icon: Icons.sync_rounded,
          onTap: _syncing ? null : _runSync,
          afterWidget: _syncing
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
      ],
    );
  }
}
