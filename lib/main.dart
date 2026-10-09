import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_client.dart';

const _apiBaseUrl = String.fromEnvironment('API_BASE_URL');

void main() {
  runApp(const SignalsApp());
}

class SignalsApp extends StatelessWidget {
  const SignalsApp({super.key});

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
      home: _apiBaseUrl.isEmpty
          ? const ServerSetupPage()
          : LoginPage(client: ApiClient(_apiBaseUrl)),
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
  var _registering = false;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _phone.dispose();
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
        setState(() => _registering = false);
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
                      validator: (value) => value == null || value.length < 10
                          ? 'يجب أن تكون كلمة المرور 10 محارف على الأقل'
                          : null,
                    ),
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
                          : Text(_registering ? 'إنشاء الحساب' : 'دخول'),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _registering = !_registering;
                                _error = null;
                              }),
                      child: Text(
                        _registering
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
  const SignalsPage({required this.client, super.key});

  final ApiClient client;

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
          final signals = snapshot.data!;
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
              ),
            ),
          );
        },
      ),
    );
  }
}

class SignalCard extends StatelessWidget {
  const SignalCard({required this.signal, required this.client, super.key});

  final Map<String, dynamic> signal;
  final ApiClient client;

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
          builder: (_) => SignalDetails(signal: signal, client: client),
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
              Text('درجة التوافق: ${score.toStringAsFixed(0)}/100'),
              const SizedBox(height: 6),
              Text('الدخول: ${_string(signal, 'entry', '—')}'),
              Text('الحالة: ${_string(signal, 'status', '—')}'),
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
  const SignalDetails({required this.signal, required this.client, super.key});

  final Map<String, dynamic> signal;
  final ApiClient client;

  @override
  Widget build(BuildContext context) {
    final targets = signal['targets'];
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
            Text(
              'درجة التوافق: ${_number(signal, 'score', 0).toStringAsFixed(0)}/100 '
              '(ليست احتمال ربح)',
            ),
            const SizedBox(height: 12),
            _DetailRow('المنصة', _string(signal, 'exchange', '—')),
            _DetailRow('الدخول', _string(signal, 'entry', '—')),
            _DetailRow('وقف الخسارة', _string(signal, 'stopLoss', '—')),
            if (targets is List)
              for (var i = 0; i < targets.length && i < 3; i++)
                _DetailRow('الهدف ${i + 1}', '${targets[i]}'),
            if (levels is Map)
              for (final entry in levels.entries)
                _DetailRow(entry.key, '${entry.value}'),
            const SizedBox(height: 8),
            const Text('سبب الإشارة', style: TextStyle(fontWeight: FontWeight.bold)),
            Text(_displayList(rationale)),
            if (signal['createdAt'] != null)
              Text('وقت الإنشاء: ${_localTime(signal['createdAt'])}'),
            const SizedBox(height: 16),
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
                      const SnackBar(content: Text('تم تسجيل دخولك لهذه الصفقة.')),
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

  @override
  void initState() {
    super.initState();
    _markets = widget.client.getMarkets();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _find() {
    setState(() => _markets = widget.client.getMarkets(query: _search.text.trim()));
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

class _AccountPageState extends State<AccountPage> {
  late Future<Map<String, dynamic>> _entitlement;

  @override
  void initState() {
    super.initState();
    _entitlement = widget.client.getEntitlement();
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
                      Text('حالة الوصول: ${_string(data, 'status', '—')}'),
                      Text(
                        'ينتهي في: ${_localTime(data['expiresAt'] ?? data['trialEndsAt'])}',
                      ),
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
            subtitle: Text('سيتم تفعيل التنبيهات بعد إعداد خدمة الإشعارات بالخادم.'),
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
  return item is String && item.isNotEmpty ? item : fallback;
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

String _localTime(Object? value) {
  if (value is! String) return '—';
  final parsed = DateTime.tryParse(value);
  return parsed?.toLocal().toString() ?? value;
}
