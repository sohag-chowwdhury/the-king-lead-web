import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const sessionLength = Duration(days: 7);
final secureFunctions = FirebaseFunctions.instanceFor(region: 'asia-south1');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: 'AIzaSyBhAD9p4TbXZUHd-6_cd75kCQh4yZNfUyw',
      appId: '1:901945590076:android:3694d5babea31c05761e39',
      messagingSenderId: '901945590076',
      projectId: 'the-king-ebce5',
      storageBucket: 'the-king-ebce5.firebasestorage.app',
    ),
  );
  FirebaseFirestore.instance.settings =
      const Settings(persistenceEnabled: true);
  runApp(const MyApp());
}

CollectionReference<Map<String, dynamic>> collection(String name) =>
    FirebaseFirestore.instance
        .collection('users')
        .doc(FirebaseAuth.instance.currentUser!.uid)
        .collection(name);

class AppUser {
  final String id;
  final String name;
  final String role;
  final bool active;
  final int sessionVersion;

  const AppUser(
    this.id,
    this.name,
    this.role, {
    this.active = true,
    this.sessionVersion = 0,
  });

  bool get isAdmin => role == 'superadmin';

  factory AppUser.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    return AppUser(
      doc.id,
      data['name'] ?? 'জানা নাই',
      data['role'] ?? 'staff',
      active: data['active'] ?? true,
      sessionVersion: data['sessionVersion'] ?? 0,
    );
  }
}

final signedInUser = ValueNotifier<AppUser?>(null);
final availableUsers = ValueNotifier<List<AppUser>>([]);

Future<void> saveSession(AppUser user) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('kingUser', user.id);
  await prefs.setInt('kingLoginAt', DateTime.now().millisecondsSinceEpoch);
  await prefs.setInt('kingSessionVersion', user.sessionVersion);
}

Future<void> logout() async {
  await FirebaseAuth.instance.signOut();
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('kingUser');
  await prefs.remove('kingLoginAt');
  await prefs.remove('kingSessionVersion');
  signedInUser.value = null;
}

void toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'The King Lead',
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: const Color(0xff05070b),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xff35b9ff),
            secondary: Color(0xff8b5cf6),
            surface: Color(0xff0d1420),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        home: ValueListenableBuilder<AppUser?>(
          valueListenable: signedInUser,
          builder: (_, user, __) =>
              user == null ? const LoginPage() : HomeShell(user: user),
        ),
      );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final pin = TextEditingController();
  List<AppUser> users = [];
  String? selectedId;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final response = await secureFunctions
          .httpsCallable('listAppUsers')
          .call<Map<String, dynamic>>();
      final rawUsers = List<Map<String, dynamic>>.from(
          (response.data['users'] as List).map((item) => Map<String, dynamic>.from(item)));
      users = rawUsers
          .map((data) => AppUser(
                data['id'],
                data['name'] ?? 'জানা নাই',
                data['role'] ?? 'staff',
                active: data['active'] ?? true,
                sessionVersion: data['sessionVersion'] ?? 0,
              ))
          .toList();
      availableUsers.value = users;
      final activeUsers = users.where((user) => user.active);
      selectedId = activeUsers.isEmpty ? null : activeUsers.first.id;
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString('kingUser');
      final loginAt = prefs.getInt('kingLoginAt') ?? 0;
      final savedVersion = prefs.getInt('kingSessionVersion') ?? -1;
      final validTime = DateTime.now().millisecondsSinceEpoch - loginAt <
          sessionLength.inMilliseconds;
      final firebaseUser = FirebaseAuth.instance.currentUser;
      if (savedId != null && validTime && firebaseUser != null) {
        final token = await firebaseUser.getIdTokenResult(true);
        if (token.claims?['appUserId'] != savedId) {
          await logout();
          return;
        }
        final match = users.where((user) => user.id == savedId);
        if (match.isNotEmpty) {
          final user = match.first;
          if (user.active &&
              (user.isAdmin || user.sessionVersion == savedVersion)) {
            signedInUser.value = user;
            return;
          }
        }
      }
    } catch (error) {
      if (mounted) toast(context, 'Login error: $error');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> enter() async {
    if (selectedId == null || pin.text.trim().isEmpty) return;
    final user = users.firstWhere((item) => item.id == selectedId);
    if (!user.active) {
      toast(context, 'এই User Block করা আছে');
      return;
    }
    setState(() => loading = true);
    try {
      final response = await secureFunctions
          .httpsCallable('loginWithPin')
          .call<Map<String, dynamic>>({
        'userId': user.id,
        'pin': pin.text.trim(),
      });
      await FirebaseAuth.instance.signInWithCustomToken(response.data['token']);
      final securedUser = AppUser(
        response.data['user']['id'],
        response.data['user']['name'],
        response.data['user']['role'],
        active: true,
        sessionVersion: response.data['user']['sessionVersion'] ?? 0,
      );
      signedInUser.value = securedUser;
      await saveSession(securedUser);
    } on FirebaseFunctionsException catch (error) {
      if (mounted) toast(context, error.message ?? 'PIN সঠিক নয়');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                children: [
                  const CircleAvatar(
                    radius: 40,
                    child: Text('K', style: TextStyle(fontSize: 38)),
                  ),
                  const SizedBox(height: 16),
                  const Text('The King Lead',
                      style:
                          TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                  const Text('The King International Services'),
                  const SizedBox(height: 28),
                  if (loading)
                    const CircularProgressIndicator()
                  else ...[
                    DropdownButtonFormField<String>(
                      initialValue: selectedId,
                      decoration: const InputDecoration(labelText: 'User'),
                      items: users
                          .where((user) => user.active)
                          .map((user) => DropdownMenuItem(
                                value: user.id,
                                child: Text(
                                    '${user.name} • ${user.isAdmin ? 'Super Admin' : 'Staff'}'),
                              ))
                          .toList(),
                      onChanged: (value) => setState(() => selectedId = value),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: pin,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: 'PIN'),
                      onSubmitted: (_) => enter(),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: enter,
                        child: const Text('প্রবেশ করুন'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
}

class Lead {
  final String id;
  final String name;
  final String mobile;
  final String district;
  final String saudi;
  final String passport;
  final String status;
  final String comment;
  final String source;
  final String interest;
  final String broker;
  final bool followUpComplete;
  final String assignedId;
  final String assignedName;
  final String creatorId;
  final DateTime followUp;
  final DateTime createdAt;

  Lead({
    required this.id,
    required this.name,
    required this.mobile,
    required this.district,
    required this.saudi,
    required this.passport,
    required this.status,
    required this.comment,
    required this.source,
    required this.interest,
    required this.broker,
    required this.followUpComplete,
    required this.assignedId,
    required this.assignedName,
    required this.creatorId,
    required this.followUp,
    required this.createdAt,
  });

  factory Lead.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    return Lead(
      id: doc.id,
      name: data['name'] ?? 'জানা নাই',
      mobile: data['mobile'] ?? '',
      district: data['district'] ?? 'জেলা জানা নাই',
      saudi: data['saudi'] ?? 'নতুন',
      passport: data['passport'] ?? 'নেই',
      status: data['status'] ?? 'New',
      comment: data['comment'] ?? '',
      source: data['source'] ?? '',
      interest: data['interest'] ?? '',
      broker: data['broker'] ?? '',
      followUpComplete: data['followUpComplete'] ?? false,
      assignedId: data['assignedToId'] ?? '',
      assignedName: data['assignedToName'] ?? 'Unassigned',
      creatorId: data['createdById'] ?? '',
      followUp:
          (data['followup'] as Timestamp?)?.toDate() ?? DateTime.now(),
      createdAt:
          (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}

Stream<List<Lead>> leadStream(AppUser user) => collection('leads')
    .orderBy('createdAt', descending: true)
    .snapshots()
    .map((snapshot) {
      final all = snapshot.docs.map(Lead.fromDoc).toList();
      if (user.isAdmin) return all;
      return all
          .where((lead) =>
              lead.assignedId == user.id || lead.creatorId == user.id)
          .toList();
    });

class HomeShell extends StatefulWidget {
  final AppUser user;
  const HomeShell({required this.user, super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;
  StreamSubscription? userGuard;

  @override
  void initState() {
    super.initState();
    if (!widget.user.isAdmin) {
      userGuard = collection('staff').doc(widget.user.id).snapshots().listen(
        (doc) {
          if (!doc.exists) {
            logout();
            return;
          }
          final current = AppUser.fromDoc(doc);
          if (!current.active ||
              current.sessionVersion != widget.user.sessionVersion) {
            logout();
          }
        },
      );
    }
  }

  @override
  void dispose() {
    userGuard?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      DashboardPage(user: widget.user),
      LeadListPage(user: widget.user, mode: 'all'),
      LeadListPage(user: widget.user, mode: 'today'),
      LeadListPage(user: widget.user, mode: 'follow'),
      LeadFormPage(user: widget.user),
    ];
    final destinations = <NavigationDestination>[
      const NavigationDestination(
          icon: Icon(Icons.dashboard_rounded), label: 'Dashboard'),
      const NavigationDestination(icon: Icon(Icons.people), label: 'Leads'),
      const NavigationDestination(
          icon: Icon(Icons.today_rounded), label: 'Today'),
      const NavigationDestination(
          icon: Icon(Icons.event_repeat), label: 'Follow-up'),
      const NavigationDestination(
          icon: Icon(Icons.person_add_alt_1), label: 'Add'),
    ];
    if (widget.user.isAdmin) {
      pages.add(const SettingsPage());
      destinations.add(const NavigationDestination(
          icon: Icon(Icons.settings), label: 'Settings'));
    }
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('The King Lead'),
            Text(
              '${widget.user.name} • ${widget.user.isAdmin ? 'Super Admin' : 'Staff'}',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
        actions: [
          IconButton(
              tooltip: 'Logout',
              onPressed: logout,
              icon: const Icon(Icons.logout)),
        ],
      ),
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: destinations,
      ),
    );
  }
}

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

class DashboardPage extends StatelessWidget {
  final AppUser user;
  const DashboardPage({required this.user, super.key});

  @override
  Widget build(BuildContext context) => StreamBuilder<List<Lead>>(
        stream: leadStream(user),
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final leads = snapshot.data!;
          final now = DateTime.now();
          final counts = <String, int>{
            'New': leads.where((lead) => lead.status == 'New').length,
            'Follow-up': leads.where((lead) => lead.status == 'Follow-up').length,
            'Qualified': leads.where((lead) => lead.status == 'Qualified').length,
            'Successful':
                leads.where((lead) => lead.status == 'Successful').length,
          };
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                user.isAdmin ? 'সব Lead Dashboard' : '${user.name}-এর Leads',
                style:
                    const TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
              ),
              const Text('Realtime update'),
              const SizedBox(height: 14),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.55,
                children: [
                  StatCard('আজকের ফলোআপ',
                      leads.where((lead) => sameDay(lead.followUp, now)).length,
                      const Color(0xff22c55e)),
                  StatCard('আজকের ইনপুট',
                      leads.where((lead) => sameDay(lead.createdAt, now)).length,
                      const Color(0xff38bdf8)),
                  StatCard(
                      'Overdue',
                      leads
                          .where((lead) =>
                              lead.followUp.isBefore(now) &&
                              !lead.followUpComplete)
                          .length,
                      const Color(0xfff97316)),
                  StatCard('Qualified', counts['Qualified']!,
                      const Color(0xffa78bfa)),
                ],
              ),
              const SizedBox(height: 10),
              StatusGraph(counts: counts),
              const SizedBox(height: 18),
              const Text('সাম্প্রতিক লিড',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ...leads.take(3).map((lead) => LeadCard(lead: lead, user: user)),
            ],
          );
        },
      );
}

class StatCard extends StatelessWidget {
  final String title;
  final int count;
  final Color color;
  const StatCard(this.title, this.count, this.color, {super.key});

  @override
  Widget build(BuildContext context) => Card(
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: color, width: 4)),
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$count',
                  style: TextStyle(
                      color: color, fontSize: 28, fontWeight: FontWeight.bold)),
              Text(title),
            ],
          ),
        ),
      );
}

class StatusGraph extends StatelessWidget {
  final Map<String, int> counts;
  const StatusGraph({required this.counts, super.key});

  static const colors = [
    Color(0xff38bdf8),
    Color(0xfff59e0b),
    Color(0xffa78bfa),
    Color(0xff22c55e),
  ];

  @override
  Widget build(BuildContext context) {
    final maxValue = counts.values.fold<int>(1, (a, b) => a > b ? a : b);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Lead Status Graph',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 18),
            ...counts.entries.toList().asMap().entries.map((entry) {
              final item = entry.value;
              final ratio = item.value / maxValue;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    SizedBox(width: 78, child: Text(item.key)),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (_, size) => Stack(
                          children: [
                            Container(
                              height: 18,
                              decoration: BoxDecoration(
                                color: Colors.white10,
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 500),
                              height: 18,
                              width: size.maxWidth * ratio,
                              decoration: BoxDecoration(
                                color: colors[entry.key],
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                        width: 34,
                        child: Text('${item.value}',
                            textAlign: TextAlign.end)),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class LeadListPage extends StatefulWidget {
  final AppUser user;
  final String mode;
  const LeadListPage({required this.user, required this.mode, super.key});

  @override
  State<LeadListPage> createState() => _LeadListPageState();
}

class _LeadListPageState extends State<LeadListPage> {
  static const pageSize = 50;
  int page = 0;
  String status = 'সব';
  String source = 'সব';
  String interest = 'সব';
  String district = 'সব';
  String broker = 'সব';
  bool newestFirst = true;

  bool get hasFilter =>
      status != 'সব' || source != 'সব' || interest != 'সব' ||
      district != 'সব' || broker != 'সব';

  Future<void> showFilters(List<Lead> leads) async {
    final configuredSources = await activeOptionNames(
        'lead_sources', ['TikTok', 'Facebook', 'Direct', 'অন্যান্য']);
    final configuredTopics = await activeOptionNames(
        'interest_topics', ['সৌদি শ্রমিক ভিসা', 'টিকিট', 'ভিসা প্রসেসিং']);
    final configuredBrokers = await activeOptionNames('brokers', []);
    if (!mounted) return;
    List<String> allOptions(
        List<String> configured, String Function(Lead) pick) {
      final options = {...configured, ...leads.map(pick)}
          .where((value) => value.isNotEmpty)
          .toList()
        ..sort();
      return ['সব', ...options];
    }
    var nextStatus = status;
    var nextSource = source;
    var nextInterest = interest;
    var nextDistrict = district;
    var nextBroker = broker;
    var nextNewest = newestFirst;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          Widget filterDrop(String label, String value, List<String> items,
                  ValueChanged<String?> change) =>
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DropdownButtonFormField<String>(
                  initialValue: items.contains(value) ? value : 'সব',
                  isExpanded: true,
                  decoration: InputDecoration(labelText: label),
                  items: items
                      .map((item) =>
                          DropdownMenuItem(value: item, child: Text(item)))
                      .toList(),
                  onChanged: change,
                ),
              );
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  18, 18, 18, 18 + MediaQuery.of(context).viewInsets.bottom),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.filter_alt),
                        SizedBox(width: 8),
                        Text('Lead Filter',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    filterDrop('Status', nextStatus,
                        ['সব', ...leadStatuses],
                        (value) => setSheetState(() => nextStatus = value!)),
                    filterDrop('Lead Source', nextSource,
                        allOptions(configuredSources, (lead) => lead.source),
                        (value) => setSheetState(() => nextSource = value!)),
                    filterDrop('আগ্রহের বিষয়', nextInterest,
                        allOptions(configuredTopics, (lead) => lead.interest),
                        (value) => setSheetState(() => nextInterest = value!)),
                    filterDrop('জেলা', nextDistrict,
                        ['সব', ...districts],
                        (value) => setSheetState(() => nextDistrict = value!)),
                    filterDrop('Broker', nextBroker,
                        allOptions(configuredBrokers, (lead) => lead.broker),
                        (value) => setSheetState(() => nextBroker = value!)),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('নতুন Lead সবার উপরে'),
                      subtitle: Text(nextNewest ? 'Newest first' : 'Oldest first'),
                      value: nextNewest,
                      onChanged: (value) =>
                          setSheetState(() => nextNewest = value),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              setState(() {
                                status = source = interest = district = broker = 'সব';
                                newestFirst = true;
                                page = 0;
                              });
                              Navigator.pop(sheetContext);
                            },
                            child: const Text('Reset'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              setState(() {
                                status = nextStatus;
                                source = nextSource;
                                interest = nextInterest;
                                district = nextDistrict;
                                broker = nextBroker;
                                newestFirst = nextNewest;
                                page = 0;
                              });
                              Navigator.pop(sheetContext);
                            },
                            child: const Text('Apply Filter'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<Lead>>(
        stream: leadStream(widget.user),
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          var items = snapshot.data!;
          final allItems = [...items];
          final now = DateTime.now();
          if (widget.mode == 'today') {
            items = items.where((lead) => sameDay(lead.createdAt, now)).toList();
          }
          if (widget.mode == 'follow') {
            items = items
                .where((lead) =>
                    !lead.followUpComplete && sameDay(lead.followUp, now))
                .toList();
          }
          if (status != 'সব') items = items.where((lead) => lead.status == status).toList();
          if (source != 'সব') items = items.where((lead) => lead.source == source).toList();
          if (interest != 'সব') {
            items = items.where((lead) => lead.interest == interest).toList();
          }
          if (district != 'সব') {
            items = items.where((lead) => lead.district == district).toList();
          }
          if (broker != 'সব') {
            items = items.where((lead) => lead.broker == broker).toList();
          }
          items.sort((a, b) => newestFirst
              ? b.createdAt.compareTo(a.createdAt)
              : a.createdAt.compareTo(b.createdAt));
          final totalPages = items.isEmpty ? 1 : (items.length / pageSize).ceil();
          if (page >= totalPages) page = totalPages - 1;
          final start = page * pageSize;
          final end = (start + pageSize).clamp(0, items.length);
          final visible = items.sublist(start, end);
          final title = widget.mode == 'today'
              ? 'আজকের Lead'
              : widget.mode == 'follow'
                  ? 'আজকের Follow-up'
                  : 'সব Lead';
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('$title (${items.length})',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                      tooltip: 'Filter Leads',
                      onPressed: () => showFilters(allItems),
                      icon: Badge(
                        isLabelVisible: hasFilter,
                        child: const Icon(Icons.filter_alt_outlined),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: visible.isEmpty
                    ? const Center(child: Text('কোনো লিড পাওয়া যায়নি'))
                    : ListView(
                        padding: const EdgeInsets.all(10),
                        children: visible
                            .map((lead) =>
                                LeadCard(lead: lead, user: widget.user))
                            .toList(),
                      ),
              ),
              if (items.length > pageSize)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: 'Previous 50',
                          onPressed: page > 0
                              ? () => setState(() => page--)
                              : null,
                          icon: const Icon(Icons.chevron_left),
                        ),
                        Text('Page ${page + 1} / $totalPages  •  ৫০টি করে'),
                        IconButton(
                          tooltip: 'Next 50',
                          onPressed: page + 1 < totalPages
                              ? () => setState(() => page++)
                              : null,
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      );
}

class LeadCard extends StatelessWidget {
  final Lead lead;
  final AppUser user;
  const LeadCard({required this.lead, required this.user, super.key});

  String get digits => lead.mobile.replaceAll(RegExp(r'\D'), '');

  Future<void> open(String uri) =>
      launchUrl(Uri.parse(uri), mode: LaunchMode.externalApplication);

  Future<void> openImo(BuildContext context) async {
    final uri = Uri.parse('imo://chat?number=+88$digits');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      await Clipboard.setData(ClipboardData(text: lead.mobile));
      if (context.mounted) toast(context, 'IMO নম্বর Copy হয়েছে');
    }
  }

  Future<void> remove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('লিড Delete করবেন?'),
            content: const Text('লিডটি স্থায়ীভাবে মুছে যাবে।'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('না')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Delete')),
            ],
          ),
        ) ??
        false;
    if (confirmed) await collection('leads').doc(lead.id).delete();
  }

  Future<void> completeFollowUp(BuildContext context) async {
    await collection('leads').doc(lead.id).update({
      'followUpComplete': true,
      'followUpCompletedAt': FieldValue.serverTimestamp(),
    });
    if (context.mounted) toast(context, 'Follow-up Complete হয়েছে');
  }

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(lead.name.isEmpty ? 'জানা নাই' : lead.name,
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.bold)),
                        Text(lead.mobile),
                      ],
                    ),
                  ),
                  if (!lead.followUpComplete)
                    IconButton(
                      tooltip: lead.followUp.isBefore(DateTime.now())
                          ? 'Follow-up Overdue'
                          : 'Follow-up বাকি',
                      onPressed: () => completeFollowUp(context),
                      icon: Icon(
                        lead.followUp.isBefore(DateTime.now())
                            ? Icons.notification_important
                            : Icons.notifications_active,
                        color: lead.followUp.isBefore(DateTime.now())
                            ? Colors.red
                            : Colors.amber,
                      ),
                    )
                  else
                    const Tooltip(
                      message: 'Follow-up Complete',
                      child: Icon(Icons.notifications_off, color: Colors.green),
                    ),
                  Chip(label: Text(lead.status)),
                ],
              ),
              const Divider(),
              Text('Assigned: ${lead.assignedName}',
                  style: const TextStyle(
                      color: Color(0xff55e1ff), fontWeight: FontWeight.bold)),
              Text('${lead.district} • ${lead.saudi} • পাসপোর্ট ${lead.passport}'),
              if (lead.source.isNotEmpty) Text('Source: ${lead.source}'),
              if (lead.interest.isNotEmpty) Text('আগ্রহ: ${lead.interest}'),
              if (lead.broker.isNotEmpty) Text('Broker: ${lead.broker}'),
              Text(
                  'ফলোআপ: ${lead.followUp.day}/${lead.followUp.month}/${lead.followUp.year}  ${TimeOfDay.fromDateTime(lead.followUp).format(context)}'),
              if (lead.comment.isNotEmpty) Text(lead.comment),
              Wrap(
                children: [
                  IconButton(
                      tooltip: 'Call',
                      onPressed: () => open('tel:${lead.mobile}'),
                      icon: const Icon(Icons.call)),
                  IconButton(
                      tooltip: 'WhatsApp',
                      onPressed: () => open('https://wa.me/88$digits'),
                      icon: const Icon(Icons.chat, color: Colors.green)),
                  IconButton(
                      tooltip: 'IMO',
                      onPressed: () => openImo(context),
                      icon: const Icon(Icons.video_call, color: Colors.blue)),
                  IconButton(
                    tooltip: 'Edit',
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              LeadFormPage(user: user, lead: lead)),
                    ),
                    icon: const Icon(Icons.edit),
                  ),
                  if (user.isAdmin)
                    IconButton(
                        tooltip: 'Delete',
                        onPressed: () => remove(context),
                        icon: const Icon(Icons.delete, color: Colors.red)),
                ],
              ),
            ],
          ),
        ),
      );
}

const districts = [
  'জেলা জানা নাই', 'বাগেরহাট', 'বান্দরবান', 'বরগুনা', 'বরিশাল', 'ভোলা', 'বগুড়া',
  'ব্রাহ্মণবাড়িয়া', 'চাঁদপুর', 'চাঁপাইনবাবগঞ্জ', 'চট্টগ্রাম', 'চুয়াডাঙ্গা', 'কুমিল্লা',
  'কক্সবাজার', 'ঢাকা', 'দিনাজপুর', 'ফরিদপুর', 'ফেনী', 'গাইবান্ধা', 'গাজীপুর',
  'গোপালগঞ্জ', 'হবিগঞ্জ', 'জামালপুর', 'যশোর', 'ঝালকাঠি', 'ঝিনাইদহ', 'জয়পুরহাট',
  'খাগড়াছড়ি', 'খুলনা', 'কিশোরগঞ্জ', 'কুড়িগ্রাম', 'কুষ্টিয়া', 'লক্ষ্মীপুর',
  'লালমনিরহাট', 'মাদারীপুর', 'মাগুরা', 'মানিকগঞ্জ', 'মেহেরপুর', 'মৌলভীবাজার',
  'মুন্সিগঞ্জ', 'ময়মনসিংহ', 'নওগাঁ', 'নড়াইল', 'নারায়ণগঞ্জ', 'নরসিংদী', 'নাটোর',
  'নেত্রকোনা', 'নীলফামারী', 'নোয়াখালী', 'পাবনা', 'পঞ্চগড়', 'পটুয়াখালী',
  'পিরোজপুর', 'রাজবাড়ী', 'রাজশাহী', 'রাঙামাটি', 'রংপুর', 'সাতক্ষীরা',
  'শরীয়তপুর', 'শেরপুর', 'সিরাজগঞ্জ', 'সুনামগঞ্জ', 'সিলেট', 'টাঙ্গাইল', 'ঠাকুরগাঁও'
];

const leadStatuses = [
  'New',
  'Follow-up',
  'Contacted',
  'Qualified',
  'Successful',
  'Closed',
  'Office Visit',
  'Passport Collected',
  'Eligible Check',
  'Medical',
  'Police Clearance',
  'Waiting for Flight',
  'Done',
];

class LeadFormPage extends StatefulWidget {
  final AppUser user;
  final Lead? lead;
  const LeadFormPage({required this.user, this.lead, super.key});

  @override
  State<LeadFormPage> createState() => _LeadFormPageState();
}

class _LeadFormPageState extends State<LeadFormPage> {
  final formKey = GlobalKey<FormState>();
  late final name =
      TextEditingController(text: widget.lead?.name ?? 'জানা নাই');
  late final mobile = TextEditingController(text: widget.lead?.mobile);
  late final comment = TextEditingController(text: widget.lead?.comment);
  late String district = widget.lead?.district ?? 'জেলা জানা নাই';
  late String saudi = widget.lead?.saudi ?? 'নতুন';
  late String passport = widget.lead?.passport ?? 'আছে';
  late String status = widget.lead?.status ?? 'New';
  late String assignedId = widget.lead?.assignedId ?? widget.user.id;
  late String assignedName = widget.lead?.assignedName ?? widget.user.name;
  late String source = widget.lead?.source ?? '';
  late String interest = widget.lead?.interest ?? '';
  late final brokerController = TextEditingController(text: widget.lead?.broker);
  late String broker = widget.lead?.broker ?? '';
  late DateTime followUp =
      widget.lead?.followUp ?? DateTime.now().add(const Duration(days: 1));
  List<AppUser> staff = [];
  List<String> sources = [];
  List<String> topics = [];
  List<String> brokers = [];
  bool loading = true;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    loadOptions();
  }

  Future<void> loadOptions() async {
    staff = availableUsers.value.where((item) => item.active).toList();
    sources = await activeOptionNames(
        'lead_sources', ['TikTok', 'Facebook', 'Direct', 'অন্যান্য']);
    topics = await activeOptionNames(
        'interest_topics', ['সৌদি শ্রমিক ভিসা', 'টিকিট', 'ভিসা প্রসেসিং']);
    brokers = await activeOptionNames('brokers', []);
    if (source == 'অন্যান্য' && broker.isEmpty && brokers.isNotEmpty) {
      broker = brokers.first;
      brokerController.text = broker;
    }
    if (source.isEmpty && sources.isNotEmpty) source = sources.first;
    if (interest.isEmpty && topics.isNotEmpty) interest = topics.first;
    if (!staff.any((item) => item.id == assignedId)) {
      assignedId = widget.user.id;
      assignedName = widget.user.name;
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> chooseFollowUp() async {
    final date = await showDatePicker(
      context: context,
      initialDate: followUp,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(followUp),
    );
    if (time == null) return;
    setState(() => followUp =
        DateTime(date.year, date.month, date.day, time.hour, time.minute));
  }

  Future<void> save() async {
    if (!formKey.currentState!.validate()) return;
    setState(() => saving = true);
    try {
      final data = <String, dynamic>{
        'name': name.text.trim().isEmpty ? 'জানা নাই' : name.text.trim(),
        'mobile': mobile.text.trim(),
        'district': district,
        'saudi': saudi,
        'passport': passport,
        'status': status,
        'comment': comment.text.trim(),
        'source': source,
        'interest': interest,
        'broker': source == 'অন্যান্য'
            ? (brokerController.text.trim().isNotEmpty
                ? brokerController.text.trim()
                : broker)
            : '',
        'followUpComplete': widget.lead?.followUpComplete ?? false,
        'assignedToId': assignedId,
        'assignedToName': assignedName,
        'followup': Timestamp.fromDate(followUp),
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (widget.lead == null) {
        data.addAll({
          'createdAt': FieldValue.serverTimestamp(),
          'createdById': widget.user.id,
          'createdByName': widget.user.name,
        });
        await collection('leads').add(data);
      } else {
        await collection('leads').doc(widget.lead!.id).update(data);
      }
      if (!mounted) return;
      toast(context, 'লিড সংরক্ষণ হয়েছে');
      if (widget.lead != null) Navigator.pop(context);
    } catch (error) {
      if (mounted) toast(context, 'Save failed: $error');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget dropdown(String label, String value, List<String> items,
          ValueChanged<String?> onChanged) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          initialValue: items.contains(value) ? value : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: items
              .map((item) => DropdownMenuItem(value: item, child: Text(item)))
              .toList(),
          onChanged: onChanged,
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Form(
        key: formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(widget.lead == null ? 'নতুন Lead' : 'Lead Update',
                style:
                    const TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
            const SizedBox(height: 14),
            TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: 'নাম')),
            const SizedBox(height: 12),
            TextFormField(
              controller: mobile,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'মোবাইল *'),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? 'মোবাইল দিন' : null,
            ),
            const SizedBox(height: 12),
            dropdown('জেলা', district, districts,
                (value) => setState(() => district = value!)),
            dropdown('Lead Source', source, sources,
                (value) => setState(() => source = value!)),
            if (source == 'অন্যান্য') ...[
              if (brokers.isNotEmpty)
                dropdown('Broker List',
                    brokers.contains(broker) ? broker : brokers.first, brokers,
                    (value) => setState(() {
                          broker = value!;
                          brokerController.text = value;
                        })),
              TextFormField(
                controller: brokerController,
                decoration: const InputDecoration(
                    labelText: 'Broker নাম',
                    prefixIcon: Icon(Icons.handshake)),
              ),
              const SizedBox(height: 12),
            ],
            dropdown('আগ্রহের বিষয়', interest, topics,
                (value) => setState(() => interest = value!)),
            dropdown('সৌদি অবস্থা', saudi, ['নতুন', 'ফেরত', 'বর্তমানে সৌদি'],
                (value) => setState(() => saudi = value!)),
            dropdown('পাসপোর্ট', passport, ['আছে', 'নেই', 'প্রক্রিয়াধীন'],
                (value) => setState(() => passport = value!)),
            dropdown(
                'Status',
                status,
                leadStatuses,
                (value) => setState(() => status = value!)),
            if (widget.user.isAdmin)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DropdownButtonFormField<String>(
                  initialValue: assignedId,
                  decoration: const InputDecoration(labelText: 'Assign User'),
                  items: staff
                      .map((person) => DropdownMenuItem(
                          value: person.id, child: Text(person.name)))
                      .toList(),
                  onChanged: (value) {
                    final person = staff.firstWhere((item) => item.id == value);
                    setState(() {
                      assignedId = person.id;
                      assignedName = person.name;
                    });
                  },
                ),
              ),
            ListTile(
              shape: RoundedRectangleBorder(
                  side: const BorderSide(color: Colors.white24),
                  borderRadius: BorderRadius.circular(14)),
              leading: const Icon(Icons.calendar_month, color: Color(0xff35b9ff)),
              title: const Text('Follow-up পরিবর্তন'),
              subtitle: Text(
                  '${followUp.day}/${followUp.month}/${followUp.year} • ${TimeOfDay.fromDateTime(followUp).format(context)}'),
              trailing: const Icon(Icons.access_time),
              onTap: chooseFollowUp,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: comment,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Comment'),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: saving ? null : save,
              icon: const Icon(Icons.save),
              label: Text(saving ? 'Saving...' : 'Save Lead'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<List<String>> activeOptionNames(
    String collectionName, List<String> defaults) async {
  final ref = collection(collectionName);
  var snapshot = await ref.get();
  final existing = snapshot.docs
      .map((doc) => '${doc.data()['name']}'.trim().toLowerCase())
      .toSet();
  for (var i = 0; i < defaults.length; i++) {
    if (!existing.contains(defaults[i].toLowerCase())) {
      await ref.add({
        'name': defaults[i],
        'active': true,
        'order': i,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }
  if (defaults.isNotEmpty) snapshot = await ref.get();
  final docs = snapshot.docs.where((doc) => doc.data()['active'] ?? true).toList()
    ..sort((a, b) =>
        (a.data()['order'] ?? 999).compareTo(b.data()['order'] ?? 999));
  return docs.map((doc) => '${doc.data()['name']}').toList();
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 4,
        child: Column(
          children: const [
            TabBar(
              isScrollable: true,
              tabs: [
                Tab(icon: Icon(Icons.campaign), text: 'Lead Source'),
                Tab(icon: Icon(Icons.topic), text: 'আগ্রহের বিষয়'),
                Tab(icon: Icon(Icons.handshake), text: 'Broker List'),
                Tab(icon: Icon(Icons.manage_accounts), text: 'User Settings'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  OptionSettings(
                      collectionName: 'lead_sources',
                      title: 'Lead Source',
                      defaults: ['TikTok', 'Facebook']),
                  OptionSettings(
                      collectionName: 'interest_topics',
                      title: 'আগ্রহের বিষয়',
                      defaults: ['সৌদি শ্রমিক ভিসা', 'টিকিট', 'ভিসা প্রসেসিং']),
                  OptionSettings(
                      collectionName: 'brokers',
                      title: 'Broker',
                      defaults: []),
                  UserSettings(),
                ],
              ),
            ),
          ],
        ),
      );
}

class OptionSettings extends StatefulWidget {
  final String collectionName;
  final String title;
  final List<String> defaults;
  const OptionSettings({
    required this.collectionName,
    required this.title,
    required this.defaults,
    super.key,
  });

  @override
  State<OptionSettings> createState() => _OptionSettingsState();
}

class _OptionSettingsState extends State<OptionSettings> {
  @override
  void initState() {
    super.initState();
    activeOptionNames(widget.collectionName, widget.defaults);
  }

  Future<void> edit(BuildContext context,
      [DocumentSnapshot<Map<String, dynamic>>? doc]) async {
    final controller = TextEditingController(text: doc?.data()?['name']);
    final accepted = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(doc == null ? 'নতুন ${widget.title}' : '${widget.title} Edit'),
            content: TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(labelText: widget.title)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Save')),
            ],
          ),
        ) ??
        false;
    if (!accepted || controller.text.trim().isEmpty) return;
    final data = {'name': controller.text.trim(), 'active': true};
    if (doc == null) {
      await collection(widget.collectionName).add({
        ...data,
        'order': DateTime.now().millisecondsSinceEpoch,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } else {
      await doc.reference.update(data);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => edit(context),
          icon: const Icon(Icons.add),
          label: const Text('Add'),
        ),
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: collection(widget.collectionName).snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final docs = snapshot.data!.docs;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(widget.title,
                    style: const TextStyle(
                        fontSize: 21, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ...docs.map((doc) => Card(
                      child: ListTile(
                        leading: Icon(
                          (doc.data()['active'] ?? true)
                              ? Icons.check_circle
                              : Icons.pause_circle,
                          color: (doc.data()['active'] ?? true)
                              ? Colors.green
                              : Colors.orange,
                        ),
                        title: Text(doc.data()['name'] ?? ''),
                        subtitle: Text((doc.data()['active'] ?? true)
                            ? 'Active'
                            : 'Deactivated'),
                        onTap: () => edit(context, doc),
                        trailing: Switch(
                          value: doc.data()['active'] ?? true,
                          onChanged: (value) =>
                              doc.reference.update({'active': value}),
                        ),
                      ),
                    )),
              ],
            );
          },
        ),
      );
}

class UserSettings extends StatelessWidget {
  const UserSettings({super.key});

  Future<void> adminCall(String name, Map<String, dynamic> data) async {
    await secureFunctions.httpsCallable(name).call(data);
  }

  Future<void> userDialog(BuildContext context,
      [DocumentSnapshot<Map<String, dynamic>>? doc]) async {
    final name = TextEditingController(text: doc?.data()?['name']);
    final pin = TextEditingController();
    final accepted = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(doc == null ? 'নতুন Staff' : 'User information Edit'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'নাম *')),
                const SizedBox(height: 10),
                TextField(
                  controller: pin,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'PIN *'),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Save')),
            ],
          ),
        ) ??
        false;
    final pinValue = pin.text.trim();
    if (!accepted ||
        name.text.trim().isEmpty ||
        (doc == null && pinValue.length < 4) ||
        (pinValue.isNotEmpty && pinValue.length < 4)) {
      return;
    }
    await adminCall('upsertStaff', {
      if (doc != null) 'staffId': doc.id,
      'name': name.text.trim(),
      if (pinValue.isNotEmpty) 'pin': pinValue,
    });
  }

  Future<void> resetPin(
      BuildContext context, DocumentSnapshot<Map<String, dynamic>> doc) async {
    final controller = TextEditingController();
    final accepted = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('PIN Reset'),
            content: TextField(
              controller: controller,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'নতুন PIN'),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Reset')),
            ],
          ),
        ) ??
        false;
    if (!accepted || controller.text.trim().length < 4) return;
    await adminCall('resetStaffPin', {
      'staffId': doc.id,
      'pin': controller.text.trim(),
    });
    if (context.mounted) toast(context, 'PIN Reset ও Session বাতিল হয়েছে');
  }

  Future<void> forceLogout(
      BuildContext context, DocumentSnapshot<Map<String, dynamic>> doc) async {
    await adminCall('forceStaffLogout', {'staffId': doc.id});
    if (context.mounted) toast(context, 'User Force Logout হয়েছে');
  }

  Future<void> setBlocked(DocumentSnapshot<Map<String, dynamic>> doc,
      bool currentlyActive) async {
    await adminCall('setStaffActive', {
      'staffId': doc.id,
      'active': !currentlyActive,
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => userDialog(context),
          icon: const Icon(Icons.person_add),
          label: const Text('Add Staff'),
        ),
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: collection('staff')
              .orderBy('createdAt', descending: true)
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('User Settings',
                    style:
                        TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
                const Text('Edit, Block, Force Logout অথবা PIN Reset করুন'),
                const SizedBox(height: 10),
                ...snapshot.data!.docs.map((doc) {
                  final data = doc.data();
                  final active = data['active'] ?? true;
                  return Card(
                    child: ExpansionTile(
                      leading: CircleAvatar(child: Text('${data['name'] ?? 'U'}'[0])),
                      title: Text(data['name'] ?? 'জানা নাই'),
                      subtitle: Text(active ? 'Active Staff' : 'Blocked'),
                      trailing: Icon(
                          active ? Icons.verified_user : Icons.block,
                          color: active ? Colors.green : Colors.red),
                      children: [
                        Wrap(
                          alignment: WrapAlignment.center,
                          children: [
                            TextButton.icon(
                                onPressed: () => userDialog(context, doc),
                                icon: const Icon(Icons.edit),
                                label: const Text('Edit')),
                            TextButton.icon(
                                onPressed: () => resetPin(context, doc),
                                icon: const Icon(Icons.password),
                                label: const Text('PIN Reset')),
                            TextButton.icon(
                                onPressed: () => forceLogout(context, doc),
                                icon: const Icon(Icons.logout),
                                label: const Text('Force Logout')),
                            TextButton.icon(
                                onPressed: () => setBlocked(doc, active),
                                icon: Icon(active ? Icons.block : Icons.lock_open),
                                label: Text(active ? 'Block' : 'Unblock')),
                          ],
                        ),
                      ],
                    ),
                  );
                }),
              ],
            );
          },
        ),
      );
}
