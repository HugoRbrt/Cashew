import 'dart:convert';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:http/http.dart' as http;

class BackendSyncService {
  final String baseUrl;
  final String apiKey;

  BackendSyncService({required this.baseUrl, required this.apiKey});

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-API-Key': apiKey,
      };

  /// Load settings from SharedPreferences, returning null if not configured.
  static BackendSyncService? fromSettings() {
    String? url = sharedPreferences.getString('backendSyncUrl');
    String? key = sharedPreferences.getString('backendSyncApiKey');
    if (url == null || url.isEmpty || key == null || key.isEmpty) return null;
    // Strip trailing slash
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    return BackendSyncService(baseUrl: url, apiKey: key);
  }

  /// Save backend settings to SharedPreferences.
  static Future<void> saveSettings(String url, String apiKey) async {
    await sharedPreferences.setString('backendSyncUrl', url);
    await sharedPreferences.setString('backendSyncApiKey', apiKey);
  }

  /// Full sync: push categories + overrides, then pull accounts + transactions.
  /// Returns a [SyncResult] with counts.
  Future<SyncResult> sync() async {
    // 1. Push categories
    int categoriesPushed = await pushCategories();

    // 2. Push overrides (user-modified transaction categories)
    int overridesPushed = await pushOverrides();

    // 3. Pull accounts as wallets
    int accountsPulled = await pullAccounts();

    // 4. Pull transactions (incremental)
    int transactionsPulled = await pullTransactions();

    // Update last sync timestamp
    await sharedPreferences.setString(
        'backendLastSync', DateTime.now().toIso8601String());

    return SyncResult(
      categoriesPushed: categoriesPushed,
      overridesPushed: overridesPushed,
      accountsPulled: accountsPulled,
      transactionsPulled: transactionsPulled,
    );
  }

  // ---------------------------------------------------------------------------
  // Push categories
  // ---------------------------------------------------------------------------
  Future<int> pushCategories() async {
    List<TransactionCategory> categories =
        await database.getAllCategories(includeSubCategories: true);

    List<Map<String, dynamic>> payload = categories.map((c) {
      return {
        'categoryPk': c.categoryPk,
        'name': c.name,
        'colour': c.colour,
        'emojiIconName': c.emojiIconName,
        'order': c.order,
        'income': c.income,
        'mainCategoryPk': c.mainCategoryPk,
      };
    }).toList();

    final response = await http.post(
      Uri.parse('$baseUrl/api/sync/categories'),
      headers: _headers,
      body: jsonEncode(payload),
    );

    if (response.statusCode != 200) {
      throw SyncException(
          'Failed to push categories: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body);
    return data['count'] as int;
  }

  // ---------------------------------------------------------------------------
  // Push overrides (transactions whose category was changed by the user)
  // ---------------------------------------------------------------------------
  Future<int> pushOverrides() async {
    // We track overrides via the "backendSyncOverrides" key in SharedPreferences.
    // This is a JSON-encoded list of {transactionPk, categoryFk}.
    String raw = sharedPreferences.getString('backendSyncOverrides') ?? '[]';
    List<dynamic> overrides = jsonDecode(raw);
    if (overrides.isEmpty) return 0;

    final response = await http.post(
      Uri.parse('$baseUrl/api/sync/overrides'),
      headers: _headers,
      body: jsonEncode(overrides),
    );

    if (response.statusCode != 200) {
      throw SyncException(
          'Failed to push overrides: ${response.statusCode} ${response.body}');
    }

    // Clear the pending overrides after successful push
    await sharedPreferences.setString('backendSyncOverrides', '[]');

    final data = jsonDecode(response.body);
    return data['applied'] as int;
  }

  /// Record a category override to be pushed on next sync.
  static Future<void> recordOverride(
      String transactionPk, String categoryFk) async {
    String raw = sharedPreferences.getString('backendSyncOverrides') ?? '[]';
    List<dynamic> overrides = jsonDecode(raw);
    // Remove any existing override for this transaction
    overrides.removeWhere((o) => o['transactionPk'] == transactionPk);
    overrides.add({'transactionPk': transactionPk, 'categoryFk': categoryFk});
    await sharedPreferences.setString(
        'backendSyncOverrides', jsonEncode(overrides));
  }

  // ---------------------------------------------------------------------------
  // Pull accounts as Cashew Wallets
  // ---------------------------------------------------------------------------
  Future<int> pullAccounts() async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/sync/accounts'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw SyncException(
          'Failed to pull accounts: ${response.statusCode} ${response.body}');
    }

    List<dynamic> accounts = jsonDecode(response.body);
    int count = 0;

    for (var acct in accounts) {
      TransactionWallet wallet = TransactionWallet(
        walletPk: acct['walletPk'],
        name: acct['name'],
        colour: null,
        iconName: null,
        dateCreated: DateTime.now(),
        dateTimeModified: DateTime.now(),
        order: acct['order'] ?? count,
        currency: acct['currency'],
        currencyFormat: null,
        decimals: 2,
        homePageWidgetDisplay: null,
      );

      await database.createOrUpdateWallet(wallet);
      count++;
    }

    return count;
  }

  // ---------------------------------------------------------------------------
  // Pull transactions (incremental via ?since= parameter)
  // ---------------------------------------------------------------------------
  Future<int> pullTransactions() async {
    String? lastSync = sharedPreferences.getString('backendLastSync');

    Uri uri = Uri.parse('$baseUrl/api/sync/transactions');
    if (lastSync != null) {
      uri = uri.replace(queryParameters: {'since': lastSync});
    }

    final response = await http.get(uri, headers: _headers);

    if (response.statusCode != 200) {
      throw SyncException(
          'Failed to pull transactions: ${response.statusCode} ${response.body}');
    }

    List<dynamic> txList = jsonDecode(response.body);
    int count = 0;

    for (var tx in txList) {
      String transactionPk = tx['transactionPk'];

      // Check if this transaction already exists and was modified by the user
      bool existsLocally = false;
      try {
        Transaction existing =
            await database.getTransactionFromPk(transactionPk);
        existsLocally = true;

        // Skip if user has locally modified this transaction
        // (dateTimeModified is after the last sync)
        if (lastSync != null && existing.dateTimeModified != null) {
          DateTime lastSyncDt = DateTime.parse(lastSync);
          if (existing.dateTimeModified!.isAfter(lastSyncDt)) {
            continue;
          }
        }
      } catch (_) {
        // Transaction doesn't exist locally — will be inserted
      }

      // Parse the date
      DateTime dateCreated;
      try {
        dateCreated = DateTime.parse(tx['dateCreated']);
      } catch (_) {
        dateCreated = DateTime.now();
      }

      // Build the transaction
      double amount = (tx['amount'] as num).toDouble();
      bool income = tx['income'] == true;

      // Cashew stores expenses as negative, income as positive
      if (!income) {
        amount = -amount.abs();
      } else {
        amount = amount.abs();
      }

      Transaction transaction = Transaction(
        transactionPk: transactionPk,
        name: tx['name'] ?? 'Unknown',
        amount: amount,
        note: tx['note'] ?? '',
        categoryFk: tx['categoryFk'] ?? '0', // '0' = balance correction/uncategorized
        walletFk: tx['walletFk'] ?? '0',
        dateCreated: dateCreated,
        dateTimeModified: DateTime.now(),
        income: income,
        paid: true,
        skipPaid: false,
      );

      try {
        await database.createOrUpdateTransaction(
          transaction,
          insert: !existsLocally,
          updateSharedEntry: false,
        );
        count++;
      } catch (e) {
        // If category doesn't exist, insert without category
        if (e.toString().contains('category-no-longer-exists')) {
          transaction = transaction.copyWith(categoryFk: '0');
          await database.createOrUpdateTransaction(
            transaction,
            insert: !existsLocally,
            updateSharedEntry: false,
          );
          count++;
        } else {
          print('Failed to sync transaction $transactionPk: $e');
        }
      }
    }

    return count;
  }
}

class SyncResult {
  final int categoriesPushed;
  final int overridesPushed;
  final int accountsPulled;
  final int transactionsPulled;

  SyncResult({
    required this.categoriesPushed,
    required this.overridesPushed,
    required this.accountsPulled,
    required this.transactionsPulled,
  });

  @override
  String toString() =>
      'Sync complete: $categoriesPushed categories pushed, '
      '$overridesPushed overrides pushed, '
      '$accountsPulled accounts pulled, '
      '$transactionsPulled transactions pulled';
}

class SyncException implements Exception {
  final String message;
  SyncException(this.message);

  @override
  String toString() => 'SyncException: $message';
}
