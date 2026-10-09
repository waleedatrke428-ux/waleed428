import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_client.dart';

const _apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: defaultApiBaseUrl,
);
final _apiBaseUrlIsValid = _isValidApiBaseUrl(_apiBaseUrl);

void main() {
  runApp(const SignalsApp());
}

bool _isValidApiBaseUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
}

class SignalsApp extends StatelessWidget {
  const SignalsApp({super.key, this.client});

  final ApiClient? client;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'إشارات السوق',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2864dc)),
        fontFamily: 'Roboto',
        useMaterial3: true,
      ),
      home: !_apiBaseUrlIsValid
          ? const ServerSetupPage()
          : SignalsPage(
              client: client ?? ApiClient(_apiBaseUrl),
              readOnly: true,
            ),
    );
  }
}

class ServerSetupPage extends StatelessWidget {
  const ServerSetupPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off, size: 56),
                SizedBox(height: 18),
                Text(
                  'الخدمة الخلفية قيد الإعداد',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 10),
                Text(
                  'لن نعرض إشارات أو أسعاراً تجريبية. بعد نشر الخادم، '
                  'سيُربط التطبيق بعنوانه الآمن.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({required this.client, super.key});

  final ApiClient client;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  final _verificationToken = TextEditingController();
  var _registering = false;
  var _verificationRequired = false;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _phone.dispose();
    _verificationToken.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_registering) {
        final result = await widget.client.register(
          phone: _phone.text.trim(),
          email: _email.text.trim(),
          password: _password.text,
        );
        if (!mounted) return;
        final message = result['message'];
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              message is String
                  ? message
                  : 'تم إنشاء الحساب. تحقق من بريدك لتأكيده.',
            ),
          ),
        );
        setState(() {
          _registering = false;
          _verificationRequired = true;
        });
      } else if (_verificationRequired) {
        await widget.client.verifyEmail(_verificationToken.text.trim());
        if (!mounted) return;
        setState(() {
          _verificationRequired = false;
          _verificationToken.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تأكيد البريد. يمكنك تسجيل الدخول.')),
        );
      } else {
        final result = await widget.client.login(
          email: _email.text.trim(),
          password: _password.text,
        );
        final token = result['accessToken'] ?? result['access_token'] ?? result['token'];
        if (token is! String || token.isEmpty) {
          throw const ApiException('لم يُرجع الخادم رمز دخول صالحاً.');
        }
        widget.client.accessToken = token;
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => UserHomePage(client: widget.client),
          ),
        );
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('إشارات السوق')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.candlestick_chart, size: 58),
                    const SizedBox(height: 20),
                    Text(
                      _registering ? 'إنشاء حساب' : 'تسجيل الدخول',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 22),
                    if (_registering) ...[
                      TextFormField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'رقم الهاتف',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => value == null || value.trim().isEmpty
                            ? 'أدخل رقم الهاتف'
                            : null,
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (_verificationRequired) ...[
                      const Text(
                        'أدخل رمز التحقق الذي وصلك على البريد الإلكتروني.',
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _verificationToken,
                        decoration: const InputDecoration(
                          labelText: 'رمز التحقق',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            _verificationRequired &&
                                    (value == null || value.trim().isEmpty)
                                ? 'أدخل رمز التحقق'
                                : null,
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (!_verificationRequired) ...[
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'البريد الإلكتروني',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || !value.contains('@')) {
                          return 'أدخل بريداً إلكترونياً صالحاً';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'كلمة المرور',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => value == null || value.length < 12
                          ? 'يجب أن تكون كلمة المرور 12 محرفاً على الأقل'
                          : null,
                    ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              _verificationRequired
                                  ? 'تأكيد البريد'
                                  : _registering
                                      ? 'إنشاء الحساب'
                                      : 'دخول',
                            ),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _registering = !_registering;
                                _verificationRequired = false;
                                _error = null;
                              }),
                      child: Text(
                        _verificationRequired
                            ? 'العودة إلى تسجيل الدخول'
                            : _registering
                                ? 'لديك حساب؟ سجل الدخول'
                                : 'إنشاء حساب جديد',
                      ),
                    ),
                    const Text(
                      'الإشارات معلومات تحليلية وليست نصيحة مالية أو ضماناً للربح.',
                      textAlign: TextAlign.center,
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
}

class UserHomePage extends StatefulWidget {
  const UserHomePage({required this.client, super.key});

  final ApiClient client;

  @override
  State<UserHomePage> createState() => _UserHomePageState();
}

class _UserHomePageState extends State<UserHomePage> {
  var _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      SignalsPage(client: widget.client),
      MarketsPage(client: widget.client),
      AlertsPage(client: widget.client),
      NewsPage(client: widget.client),
      AccountPage(client: widget.client, onLogout: _logout),
    ];
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(child: pages[_index]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (index) => setState(() => _index = index),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.bolt), label: 'الإشارات'),
            NavigationDestination(icon: Icon(Icons.search), label: 'العملات'),
            NavigationDestination(
              icon: Icon(Icons.notifications_active_outlined),
              label: 'التنبيهات',
            ),
            NavigationDestination(icon: Icon(Icons.newspaper), label: 'الأخبار'),
            NavigationDestination(icon: Icon(Icons.person), label: 'حسابي'),
          ],
        ),
      ),
    );
  }

  void _logout() {
    widget.client.accessToken = null;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => LoginPage(client: widget.client),
      ),
      (_) => false,
    );
  }
}

class SignalsPage extends StatefulWidget {
  const SignalsPage({
    required this.client,
    this.readOnly = false,
    super.key,
  });

  final ApiClient client;
  final bool readOnly;

  @override
  State<SignalsPage> createState() => _SignalsPageState();
}

class _SignalsPageState extends State<SignalsPage> {
  late Future<List<Map<String, dynamic>>> _signals;

  @override
  void initState() {
    super.initState();
    _signals = widget.client.getSignals();
  }

  Future<void> _refresh() async {
    final request = widget.client.getSignals();
    setState(() => _signals = request);
    await request;
  }

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: 'الإشارات',
      actions: [
        IconButton(
          tooltip: 'تحديث',
          onPressed: _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _signals,
        builder: (context, snapshot) {
          if (snapshot.hasError) return _ErrorView(message: '${snapshot.error}');
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final signals = widget.readOnly
              ? snapshot.data!
              : snapshot.data!
                  .where((signal) => _number(
                        signal,
                        'score',
                        _number(signal, 'strength', 0),
                      ) >=
                      65)
                  .toList(growable: false);
          if (signals.isEmpty) {
            return const _EmptyView(
              icon: Icons.hourglass_empty,
              message: 'لا توجد إشارات مستوفية للحد الأدنى حالياً.',
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: signals.length,
              itemBuilder: (context, index) => SignalCard(
                signal: signals[index],
                client: widget.client,
                readOnly: widget.readOnly,
              ),
            ),
          );
        },
      ),
    );
  }
}

class SignalCard extends StatelessWidget {
  const SignalCard({
    required this.signal,
    required this.client,
    this.readOnly = false,
    super.key,
  });

  final Map<String, dynamic> signal;
  final ApiClient client;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final symbol = _string(signal, 'symbol', '—');
    final exchange = _string(signal, 'exchange', '—');
    final side = _string(signal, 'side', _string(signal, 'direction', '—'));
    final score = _number(signal, 'score', _number(signal, 'strength', 0));
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => SignalDetails(
            signal: signal,
            client: client,
            readOnly: readOnly,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '$symbol · $exchange',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Chip(label: Text(side)),
                ],
              ),
              if (!readOnly)
                Text('درجة التوافق: ${score.toStringAsFixed(0)}/100'),
              const SizedBox(height: 6),
              Text('الدخول: ${_string(signal, 'entry', '—')}'),
              Text('الحالة: ${_string(signal, 'status', 'غير محددة')}'),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('التفاصيل'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SignalDetails extends StatelessWidget {
  const SignalDetails({
    required this.signal,
    required this.client,
    this.readOnly = false,
    super.key,
  });

  final Map<String, dynamic> signal;
  final ApiClient client;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final targets = signal['targets'];
    final takeProfits = targets ?? signal['takeProfits'];
    final rationale = signal['rationale'];
    final levels = signal['levels'];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${_string(signal, 'symbol', '—')} · ${_string(signal, 'side', '—')}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (!readOnly)
              Text(
                'درجة التوافق: ${_number(signal, 'score', 0).toStringAsFixed(0)}/100 '
                '(ليست احتمال ربح)',
              ),
            const SizedBox(height: 12),
            _DetailRow('المنصة', _string(signal, 'exchange', '—')),
            _DetailRow('الدخول', _string(signal, 'entry', '—')),
            _DetailRow('وقف الخسارة', _string(signal, 'stopLoss', '—')),
            if (signal['leverage'] != null)
              _DetailRow('الرافعة', '${signal['leverage']}x'),
            if (signal['risk_percent'] != null)
              _DetailRow('نسبة المخاطرة', '${signal['risk_percent']}%'),
            if (takeProfits is List)
              for (var i = 0; i < takeProfits.length && i < 3; i++)
                _DetailRow('الهدف ${i + 1}', '${takeProfits[i]}'),
            if (levels is Map)
              for (final entry in levels.entries)
                _DetailRow(entry.key, '${entry.value}'),
            if (rationale != null) ...[
              const Text('سبب الإشارة', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(_displayList(rationale)),
            ],
            if (signal['createdAt'] != null)
              Text('وقت الإنشاء: ${_localTime(signal['createdAt'])}'),
            const SizedBox(height: 16),
            if (!readOnly)
              FilledButton.icon(
                onPressed: () async {
                  final id = signal['id'];
                  if (id is! String || id.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('معرّف الإشارة غير صالح.')),
                    );
                    return;
                  }
                  try {
                    await client.markEntered(id);
                    if (context.mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('تم تسجيل دخولك لهذه الصفقة.'),
                        ),
                      );
                    }
                  } on ApiException catch (error) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(error.message)),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.login),
                label: const Text('دخلت الصفقة'),
              ),
            const SizedBox(height: 8),
            const Text(
              'الإشارات معلومات تحليلية فقط. العقود الآجلة عالية المخاطر '
              'وقد تؤدي إلى خسارة رأس المال.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class MarketsPage extends StatefulWidget {
  const MarketsPage({required this.client, super.key});

  final ApiClient client;

  @override
  State<MarketsPage> createState() => _MarketsPageState();
}

class _MarketsPageState extends State<MarketsPage> {
  final _search = TextEditingController();
  late Future<List<Map<String, dynamic>>> _markets;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _markets = widget.client.getMarkets();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _find() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() =>
            _markets = widget.client.getMarkets(query: _search.text.trim()));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: 'العملات',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              controller: _search,
              onChanged: (_) => _find(),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'ابحث عن رمز العملة أو المنصة',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _markets,
              builder: (context, snapshot) {
                if (snapshot.hasError) return _ErrorView(message: '${snapshot.error}');
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.data!.isEmpty) {
                  return const _EmptyView(
                    icon: Icons.search_off,
                    message: 'لم يتم العثور على عملات.',
                  );
                }
                return ListView.separated(
                  itemCount: snapshot.data!.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final market = snapshot.data![index];
                    return ListTile(
                      title: Text(_string(market, 'symbol', '—')),
                      subtitle: Text(_string(market, 'exchange', '—')),
                      trailing: market['score'] == null
                          ? null
                          : Text('${_number(market, 'score', 0).toStringAsFixed(0)}/100'),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class NewsPage extends StatefulWidget {
  const NewsPage({required this.client, super.key});

  final ApiClient client;

  @override
  State<NewsPage> createState() => _NewsPageState();
}

class _NewsPageState extends State<NewsPage> {
  late Future<List<Map<String, dynamic>>> _news;

  @override
  void initState() {
    super.initState();
    _news = widget.client.getNews();
  }

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: 'أخبار السوق',
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _news,
        builder: (context, snapshot) {
          if (snapshot.hasError) return _ErrorView(message: '${snapshot.error}');
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.data!.isEmpty) {
            return const _EmptyView(
              icon: Icons.newspaper,
              message: 'لا توجد أخبار متاحة حالياً.',
            );
          }
          return ListView.builder(
            itemCount: snapshot.data!.length,
            itemBuilder: (context, index) {
              final item = snapshot.data![index];
              return ListTile(
                title: Text(_string(item, 'title', '—')),
                subtitle: Text(
                  '${_string(item, 'source', 'مصدر غير معروف')} · '
                  '${_localTime(item['publishedAt'])}',
                ),
                trailing: const Icon(Icons.open_in_new),
                onTap: () async {
                  final url = item['url'];
                  final uri = url is String ? Uri.tryParse(url) : null;
                  if (uri != null &&
                      (uri.scheme == 'https' || uri.scheme == 'http') &&
                      await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                    return;
                  }
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('تعذّر فتح رابط الخبر.'),
                      ),
                    );
                  }
                },
              );
            },
          );
        },
      ),
    );
  }
}

class AccountPage extends StatefulWidget {
  const AccountPage({required this.client, required this.onLogout, super.key});

  final ApiClient client;
  final VoidCallback onLogout;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class AlertsPage extends StatefulWidget {
  const AlertsPage({required this.client, super.key});

  final ApiClient client;

  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  late Future<List<Map<String, dynamic>>> _alerts;
  Timer? _polling;

  @override
  void initState() {
    super.initState();
    _alerts = widget.client.getAlerts();
    _polling = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _alerts = widget.client.getAlerts());
    });
  }

  @override
  void dispose() {
    _polling?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: 'تنبيهات الصفقات',
      actions: [
        IconButton(
          tooltip: 'تحديث',
          onPressed: () => setState(() => _alerts = widget.client.getAlerts()),
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _alerts,
        builder: (context, snapshot) {
          if (snapshot.hasError) return _ErrorView(message: '${snapshot.error}');
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.data!.isEmpty) {
            return const _EmptyView(
              icon: Icons.notifications_none,
              message: 'لا توجد تحديثات لصفقات سجّلت دخولك إليها.',
            );
          }
          return ListView.builder(
            itemCount: snapshot.data!.length,
            itemBuilder: (context, index) {
              final alert = snapshot.data![index];
              final details = alert['details'];
              return ListTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: Text(
                  '${_alertLabel(alert['type'])} · '
                  '${_string(alert, 'symbol', _string(alert, 'signalId', 'صفقة'))}',
                ),
                subtitle: Text(
                  '${_localTime(alert['observedAt'])}'
                  '${details is Map<String, dynamic> ? '\n${_displayMap(details)}' : ''}',
                ),
                isThreeLine: details is Map<String, dynamic>,
              );
            },
          );
        },
      ),
    );
  }
}

class _AccountPageState extends State<AccountPage> {
  late Future<Map<String, dynamic>> _entitlement;
  late Future<Map<String, dynamic>> _sessionHours;

  @override
  void initState() {
    super.initState();
    _entitlement = widget.client.getEntitlement();
    _sessionHours = _loadSessionHours();
  }

  Future<Map<String, dynamic>> _loadSessionHours() async {
    const channel = MethodChannel('cloud_mobile_starter/device');
    final timezone = await channel.invokeMethod<String>('timezoneId');
    if (timezone == null || timezone.isEmpty) {
      throw const ApiException('تعذّر تحديد المنطقة الزمنية للجهاز.');
    }
    return widget.client.getSessionHours(timezone);
  }

  @override
  Widget build(BuildContext context) {
    final localZone = DateTime.now().timeZoneName;
    return _PageScaffold(
      title: 'حسابي',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FutureBuilder<Map<String, dynamic>>(
            future: _entitlement,
            builder: (context, snapshot) {
              if (snapshot.hasError) return _ErrorView(message: '${snapshot.error}');
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = snapshot.data!;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'حالة الوصول: '
                        '${data['active'] == true ? 'فعّال' : 'منتهي'}',
                      ),
                      Text(
                        'ينتهي في: ${_localTime(data['expiresAt'] ?? data['trialExpiresAt'])}',
                      ),
                      Text('الوقت المتبقي: ${_remaining(data)}'),
                    ],
                  ),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('التوقيت المحلي للجهاز'),
            subtitle: Text('$localZone · ${DateTime.now().timeZoneOffset}'),
          ),
                FutureBuilder<Map<String, dynamic>>(
                  future: _sessionHours,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return ListTile(
                        leading: const Icon(Icons.access_time),
                        title: const Text('ساعات جلسة لندن'),
                        subtitle: Text('تعذّر تحميل الساعات: ${snapshot.error}'),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const ListTile(
                        leading: Icon(Icons.access_time),
                        title: Text('ساعات جلسة لندن'),
                        subtitle: LinearProgressIndicator(),
                      );
                    }
                    final data = snapshot.data!;
                    final local = data['local'] ?? data['localHours'] ?? data;
                    return ListTile(
                      leading: const Icon(Icons.access_time),
                      title: const Text('جلسة لندن بالتوقيت المحلي'),
                      subtitle: Text(_sessionHoursLabel(local)),
                    );
                  },
                ),
          const ListTile(
            leading: Icon(Icons.shield_outlined),
            title: Text('لقطات الشاشة والمشاركة محظورة في التطبيق'),
            subtitle: Text(
              'قد لا يمنع التطبيق تصوير الشاشة بجهاز خارجي أو على جهاز مخترق.',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.notifications_outlined),
            title: Text('التنبيهات'),
            subtitle: Text(
              'تُحدّث التنبيهات داخل التطبيق أثناء فتحه. '
              'إشعارات الدفع بالخلفية تحتاج إعداد FCM.',
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout),
            label: const Text('تسجيل الخروج'),
          ),
          const SizedBox(height: 16),
          const Text(
            'التجربة والاشتراك والوقت المتبقي يحددها الخادم، '
            'ولا يعتمد التطبيق على ساعة الهاتف.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _PageScaffold extends StatelessWidget {
  const _PageScaffold({
    required this.title,
    required this.child,
    this.actions = const [],
  });

  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: child,
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

String _string(Map<String, dynamic> value, String key, String fallback) {
  final item = value[key];
  if (item is String && item.isNotEmpty) return item;
  if (item is num) return item.toString();
  return fallback;
}

double _number(Map<String, dynamic> value, String key, double fallback) {
  final item = value[key];
  if (item is num) return item.toDouble();
  if (item is String) return double.tryParse(item) ?? fallback;
  return fallback;
}

String _displayList(Object? value) {
  if (value is List) return value.map((item) => '• $item').join('\n');
  if (value is String) return value;
  return 'لا يوجد شرح متاح.';
}

String _displayMap(Map<String, dynamic> value) {
  return value.entries
      .map((entry) => '${entry.key}: ${entry.value}')
      .join(' · ');
}

String _alertLabel(Object? value) {
  switch (value) {
    case 'signal_created':
      return 'إشارة جديدة';
    case 'entry_reached':
      return 'وصل السعر لمنطقة الدخول';
    case 'stop_loss_hit':
      return 'تم الوصول لوقف الخسارة';
    case 'take_profit_hit':
      return 'تم الوصول لأحد الأهداف';
    case 'reversal':
      return 'رُصد انعكاس محتمل';
    default:
      return value is String ? value : 'تحديث صفقة';
  }
}

String _localTime(Object? value) {
  if (value is! String) return '—';
  final parsed = DateTime.tryParse(value);
  return parsed?.toLocal().toString() ?? value;
}

String _remaining(Map<String, dynamic> entitlement) {
  final seconds = entitlement['remainingSeconds'];
  Duration? remaining;
  if (seconds is num) {
    remaining = Duration(seconds: seconds.toInt());
  } else {
    final expires = DateTime.tryParse(
      '${entitlement['expiresAt'] ?? entitlement['trialEndsAt'] ?? ''}',
    );
    final serverNow = DateTime.tryParse('${entitlement['serverNow'] ?? ''}');
    if (expires != null && serverNow != null) {
      remaining = expires.difference(serverNow);
    }
  }
  if (remaining == null) return '—';
  if (remaining.isNegative || remaining == Duration.zero) return 'منتهي';
  final days = remaining.inDays;
  final hours = remaining.inHours.remainder(24);
  final minutes = remaining.inMinutes.remainder(60);
  return '$days يوم · $hours ساعة · $minutes دقيقة';
}

String _sessionHoursLabel(Object? value) {
  if (value is! Map<String, dynamic>) return 'الساعات غير متاحة.';
  final start = value['start'];
  final end = value['end'];
  final date = value['date'];
  if (start is! String || end is! String) return 'الساعات غير متاحة.';
  return '$start–$end${date is String ? ' · $date' : ''}';
}
