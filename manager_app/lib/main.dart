import 'package:flutter/material.dart';

import 'admin_api.dart';

const _apiBaseUrl = String.fromEnvironment('API_BASE_URL');

void main() => runApp(const ManagerApp());

bool _hasSecureApiBaseUrl() {
  final uri = Uri.tryParse(_apiBaseUrl);
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
}

class ManagerApp extends StatelessWidget {
  const ManagerApp({super.key, this.api});

  final ManagerApi? api;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'كريبتو البلحوسي - المدير',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2864dc)),
        useMaterial3: true,
      ),
      home: !_hasSecureApiBaseUrl()
          ? const _ServerSetupPage()
          : ManagerLoginPage(
              api: api ?? ManagerApi(_apiBaseUrl),
            ),
    );
  }
}

class _ServerSetupPage extends StatelessWidget {
  const _ServerSetupPage();

  @override
  Widget build(BuildContext context) => const Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'تطبيق المدير جاهز، لكن عنوان HTTPS للخادم غير مضبوط. '
                'انشر خادم FastAPI واضبط API_BASE_URL للبناء.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
}

class ManagerLoginPage extends StatefulWidget {
  const ManagerLoginPage({required this.api, super.key});

  final ManagerApi api;

  @override
  State<ManagerLoginPage> createState() => _ManagerLoginPageState();
}

class _ManagerLoginPageState extends State<ManagerLoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.login(_email.text.trim(), _password.text);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ManagerDashboard(api: widget.api),
        ),
      );
    } on ManagerApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('كريبتو البلحوسي - المدير')),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.admin_panel_settings, size: 64),
                      const SizedBox(height: 20),
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'البريد الإلكتروني للمدير',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            value == null || !value.contains('@')
                                ? 'أدخل بريداً إلكترونياً صالحاً'
                                : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _password,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'كلمة المرور',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            value == null || value.isEmpty
                                ? 'أدخل كلمة المرور'
                                : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      FilledButton(
                        onPressed: _busy ? null : _login,
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('دخول المدير'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class ManagerDashboard extends StatefulWidget {
  const ManagerDashboard({required this.api, super.key});

  final ManagerApi api;

  @override
  State<ManagerDashboard> createState() => _ManagerDashboardState();
}

class _ManagerDashboardState extends State<ManagerDashboard> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _OverviewPage(api: widget.api),
      _UsersPage(api: widget.api),
      _SignalsPage(api: widget.api),
      _SettingsPage(api: widget.api),
    ];
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('لوحة المدير'),
          actions: [
            IconButton(
              tooltip: 'تسجيل الخروج',
              onPressed: _logout,
              icon: const Icon(Icons.logout),
            ),
          ],
        ),
        body: SafeArea(child: pages[_index]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (index) => setState(() => _index = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              label: 'الرئيسية',
            ),
            NavigationDestination(
              icon: Icon(Icons.people_outline),
              label: 'المستخدمون',
            ),
            NavigationDestination(
              icon: Icon(Icons.bolt),
              label: 'الإشارات',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune),
              label: 'الإعدادات',
            ),
          ],
        ),
      ),
    );
  }

  void _logout() {
    widget.api.logout();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => ManagerLoginPage(api: widget.api),
      ),
      (_) => false,
    );
  }
}

class _OverviewPage extends StatelessWidget {
  const _OverviewPage({required this.api});

  final ManagerApi api;

  @override
  Widget build(BuildContext context) => _DataList(
        title: 'ملخص الإدارة',
        load: () async {
          final results = await Future.wait([
            api.users(),
            api.signals(),
          ]);
          return [
            {
              'title': 'عدد المستخدمين',
              'value': results[0].length.toString(),
            },
            {
              'title': 'الإشارات المسجلة',
              'value': results[1].length.toString(),
            },
            {
              'title': 'حد التوافق الأدنى',
              'value': '65/100',
            },
          ];
        },
        itemBuilder: (context, item, _) => Card(
          child: ListTile(
            title: Text(item['title'] ?? ''),
            trailing: Text(
              item['value'] ?? '',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ),
      );
}

class _UsersPage extends StatelessWidget {
  const _UsersPage({required this.api});

  final ManagerApi api;

  @override
  Widget build(BuildContext context) => _DataList(
        title: 'المستخدمون والاشتراكات',
        load: api.users,
        emptyMessage: 'لا يوجد مستخدمون.',
        itemBuilder: (context, user, refresh) => Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ListTile(
              title: Text(_text(user['email'])),
              subtitle: Text(
                'الهاتف: ${_text(user['phone'])}\n'
                'الحالة: ${_text(user['status'])}\n'
                'الوصول حتى: ${_date(user['accessEndsAt'])}',
              ),
              isThreeLine: true,
              trailing: IconButton(
                tooltip: 'تمديد شهر',
                icon: const Icon(Icons.add_card),
                onPressed: () => _confirmExtension(context, user, refresh),
              ),
            ),
          ),
        ),
      );

  Future<void> _confirmExtension(
    BuildContext context,
    Map<String, dynamic> user,
    Future<void> Function() refresh,
  ) async {
    final id = user['id'];
    if (id is! String || id.isEmpty) {
      _showMessage(context, 'معرّف المستخدم غير صالح.');
      return;
    }
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('تمديد الاشتراك'),
            content: Text('إضافة شهر واحد إلى اشتراك ${_text(user['email'])}؟'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('تأكيد'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !context.mounted) return;
    try {
      await api.extendSubscription(id);
      if (context.mounted) {
        await refresh();
      }
      if (context.mounted) {
        _showMessage(context, 'تم تمديد الاشتراك شهراً.');
      }
    } on ManagerApiException catch (error) {
      if (context.mounted) _showMessage(context, error.message);
    }
  }
}

class _SignalsPage extends StatelessWidget {
  const _SignalsPage({required this.api});

  final ManagerApi api;

  @override
  Widget build(BuildContext context) => _DataList(
        title: 'الإشارات',
        load: api.signals,
        emptyMessage: 'لا توجد إشارات.',
        itemBuilder: (context, signal, _) => Card(
          child: ListTile(
            title: Text(
              '${_text(signal['symbol'])} · ${_text(signal['exchange'])}',
            ),
            subtitle: Text(
              'الاتجاه: ${_text(signal['direction'])}\n'
              'الدخول: ${_text(signal['entry'])} · الوقف: ${_text(signal['stopLoss'])}\n'
              'الأهداف: ${_list(signal['takeProfits'])}',
            ),
            isThreeLine: true,
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${signal['score'] ?? '—'}/100'),
                Text(_text(signal['status'])),
              ],
            ),
          ),
        ),
      );
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({required this.api});

  final ManagerApi api;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  static const _exchanges = ['binance', 'bybit', 'okx'];
  final _score = TextEditingController(text: '65');
  final _selected = <String>{};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _score.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await widget.api.settings();
      final score = settings['minSignalScore'] ?? settings['minimumSignalScore'];
      final exchanges = settings['activeExchanges'] ?? settings['exchanges'];
      if (score is num) _score.text = score.toInt().toString();
      _selected
        ..clear()
        ..addAll(exchanges is List ? exchanges.whereType<String>() : const []);
      if (_selected.isEmpty) _selected.addAll(_exchanges);
    } on ManagerApiException catch (error) {
      _error = error.message;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final score = int.tryParse(_score.text);
    if (score == null || score < 65 || score > 100) {
      setState(() => _error = 'يجب أن تكون الدرجة بين 65 و100.');
      return;
    }
    if (_selected.isEmpty) {
      setState(() => _error = 'اختر منصة واحدة على الأقل.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.saveSettings(
        minimumSignalScore: score,
        exchanges: _exchanges.where(_selected.contains).toList(),
      );
      if (mounted) _showMessage(context, 'تم حفظ إعدادات التحليل.');
    } on ManagerApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'إعدادات التحليل',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _score,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'الحد الأدنى للتوافق (65–100)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        const Text('منصات بيانات السوق'),
        for (final exchange in _exchanges)
          CheckboxListTile(
            value: _selected.contains(exchange),
            title: Text(exchange.toUpperCase()),
            onChanged: (enabled) => setState(() {
              if (enabled == true) {
                _selected.add(exchange);
              } else {
                _selected.remove(exchange);
              }
            }),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const CircularProgressIndicator()
              : const Text('حفظ الإعدادات'),
        ),
        const SizedBox(height: 12),
        const Text(
          'درجة التوافق الفني ليست احتمال ربح أو ضماناً للنتيجة.',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _DataList extends StatefulWidget {
  const _DataList({
    required this.title,
    required this.load,
    required this.itemBuilder,
    this.emptyMessage = 'لا توجد بيانات.',
  });

  final String title;
  final Future<List<Map<String, dynamic>>> Function() load;
  final Widget Function(
    BuildContext,
    Map<String, dynamic>,
    Future<void> Function(),
  ) itemBuilder;
  final String emptyMessage;

  @override
  State<_DataList> createState() => _DataListState();
}

class _DataListState extends State<_DataList> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  Future<void> _refresh() async {
    final next = widget.load();
    setState(() => _future = next);
    await next;
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'تحديث',
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return _ErrorState(message: '${snapshot.error}');
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.data!.isEmpty) {
                  return _ErrorState(message: widget.emptyMessage);
                }
                return RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                    itemCount: snapshot.data!.length,
                    itemBuilder: (context, index) => widget.itemBuilder(
                      context,
                      snapshot.data![index],
                      _refresh,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(message, textAlign: TextAlign.center),
        ),
      );
}

String _text(Object? value) => value?.toString() ?? '—';

String _date(Object? value) {
  if (value is! String) return '—';
  final date = DateTime.tryParse(value);
  return date?.toLocal().toString().split('.').first ?? value;
}

String _list(Object? value) =>
    value is List ? value.map((item) => item.toString()).join(' · ') : '—';

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}
