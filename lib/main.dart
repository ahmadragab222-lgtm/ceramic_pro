import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('ceramic_pro.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getApplicationDocumentsDirectory();
    final path = p.join(dbPath.path, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE models (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            code TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            company TEXT,
            category TEXT,
            min_limit INTEGER DEFAULT 10,
            created_at TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE variants (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            model_id INTEGER,
            size TEXT,
            color TEXT,
            grade TEXT,
            location TEXT,
            quantity INTEGER DEFAULT 0,
            FOREIGN KEY (model_id) REFERENCES models (id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE transactions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            variant_id INTEGER,
            trans_type TEXT,
            quantity INTEGER,
            reason_ref TEXT,
            user_name TEXT,
            timestamp TEXT,
            FOREIGN KEY (variant_id) REFERENCES variants (id)
          )
        ''');

        final nowStr = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
        int m1 = await db.insert('models', {
          'code': 'MOD-101',
          'name': 'كليوباترا رخامي',
          'company': 'كليوباترا',
          'category': 'بلاط',
          'min_limit': 15,
          'created_at': nowStr,
        });

        int v1 = await db.insert('variants', {
          'model_id': m1,
          'size': '60x120',
          'color': 'بيج',
          'grade': 'فرز أول',
          'location': 'A-01',
          'quantity': 120,
        });

        await db.insert('transactions', {
          'variant_id': v1,
          'trans_type': 'وارد من الفرز',
          'quantity': 120,
          'reason_ref': 'رصيد افتتاحي أول المدة',
          'user_name': 'المدير',
          'timestamp': nowStr,
        });
      },
    );
  }

  Future<void> addModelWithVariant({
    required String code,
    required String name,
    required String company,
    required String category,
    required String size,
    required String color,
    required String grade,
    required String location,
    required int initialQty,
  }) async {
    final db = await instance.database;
    final nowStr = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());

    int modelId;
    final existing = await db.query('models', where: 'code = ?', whereArgs: [code]);
    if (existing.isNotEmpty) {
      modelId = existing.first['id'] as int;
    } else {
      modelId = await db.insert('models', {
        'code': code,
        'name': name,
        'company': company,
        'category': category,
        'min_limit': 10,
        'created_at': nowStr,
      });
    }

    final varId = await db.insert('variants', {
      'model_id': modelId,
      'size': size,
      'color': color,
      'grade': grade,
      'location': location,
      'quantity': initialQty,
    });

    if (initialQty > 0) {
      await db.insert('transactions', {
        'variant_id': varId,
        'trans_type': 'وارد من الفرز',
        'quantity': initialQty,
        'reason_ref': 'رصيد افتتاحي',
        'user_name': 'أمين المخزن',
        'timestamp': nowStr,
      });
    }
  }

  Future<Map<String, dynamic>> executeTransaction({
    required int variantId,
    required String transType,
    required int qty,
    required String reason,
  }) async {
    final db = await instance.database;
    final rows = await db.query('variants', where: 'id = ?', whereArgs: [variantId]);
    if (rows.isEmpty) return {'success': false, 'msg': 'الصنف غير موجود!'};

    int currentQty = rows.first['quantity'] as int;
    int newQty = currentQty;

    if (transType == 'صرف مبيعات' || transType == 'هالك أو كسر') {
      if (currentQty < qty) {
        return {'success': false, 'msg': 'الرصيد المتاح ($currentQty) لا يكفي لصرف ($qty) قطعة!'};
      }
      newQty = currentQty - qty;
    } else if (transType == 'وارد من الفرز' || transType == 'مرتجع للمخزن') {
      newQty = currentQty + qty;
    } else if (transType == 'تسوية جرد') {
      newQty = qty;
    }

    await db.update('variants', {'quantity': newQty}, where: 'id = ?', whereArgs: [variantId]);

    final nowStr = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    await db.insert('transactions', {
      'variant_id': variantId,
      'trans_type': transType,
      'quantity': qty,
      'reason_ref': reason,
      'user_name': 'مسؤول الوردية',
      'timestamp': nowStr,
    });

    return {'success': true, 'msg': 'تم الحفظ بنجاح! الرصيد الجديد: $newQty قطعة'};
  }

  Future<List<Map<String, dynamic>>> getStockList({String query = ''}) async {
    final db = await instance.database;
    String sql = '''
      SELECT v.id, m.code, m.name, m.company, m.category, v.size, v.color, v.grade, v.location, v.quantity, m.min_limit
      FROM variants v
      JOIN models m ON v.model_id = m.id
    ''';
    if (query.trim().isNotEmpty) {
      sql += " WHERE m.name LIKE '%$query\%' OR m.code LIKE '\%$query%' OR v.location LIKE '%$query\%' OR v.color LIKE '\%$query%'";
    }
    sql += " ORDER BY v.id DESC";
    return await db.rawQuery(sql);
  }

  Future<List<Map<String, dynamic>>> getStagnantItems() async {
    final db = await instance.database;
    final sql = '''
      SELECT v.id, m.name, m.code, v.color, v.grade, v.quantity,
             MAX(CASE WHEN t.trans_type = 'صرف مبيعات' THEN t.timestamp ELSE NULL END) as last_sale,
             m.created_at
      FROM variants v
      JOIN models m ON v.model_id = m.id
      LEFT JOIN transactions t ON v.id = t.variant_id
      WHERE v.quantity > 0
      GROUP BY v.id
    ''';
    final rows = await db.rawQuery(sql);
    List<Map<String, dynamic>> stagnant = [];
    final now = DateTime.now();

    for (var r in rows) {
      String? refDateStr = r['last_sale'] as String? ?? r['created_at'] as String?;
      if (refDateStr != null) {
        try {
          DateTime refDate = DateFormat('yyyy-MM-dd').parse(refDateStr);
          int diff = now.difference(refDate).inDays;
          if (diff >= 30) {
            var item = Map<String, dynamic>.from(r);
            item['days_inactive'] = diff;
            stagnant.add(item);
          }
        } catch (_) {}
      }
    }
    return stagnant;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseHelper.instance.database;
  runApp(const CeramicProApp());
}

class CeramicProApp extends StatelessWidget {
  const CeramicProApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مخزن السيراميك برو',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar', 'EG'),
      supportedLocales: const [Locale('ar', 'EG'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        primaryColor: const Color(0xFF0F172A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0284C7),
          primary: const Color(0xFF0F172A),
          secondary: const Color(0xFF0284C7),
        ),
      ),
      home: const MainDashboard(),
    );
  }
}

class MainDashboard extends StatefulWidget {
  const MainDashboard({super.key});

  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

class _MainDashboardState extends State<MainDashboard> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    StockListScreen(),
    MovementScreen(),
    AddModelScreen(),
    AlertsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مخزن السيراميك برو', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: const Color(0xFF0F172A),
      ),
      body: _screens[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: 'المخزون'),
          NavigationDestination(icon: Icon(Icons.swap_horizontal_circle_outlined), selectedIcon: Icon(Icons.swap_horizontal_circle), label: 'إضافة/صرف'),
          NavigationDestination(icon: Icon(Icons.add_box_outlined), selectedIcon: Icon(Icons.add_box), label: 'تعريف صنف'),
          NavigationDestination(icon: Icon(Icons.warning_amber_rounded), selectedIcon: Icon(Icons.warning_rounded), label: 'التنبيهات'),
        ],
      ),
    );
  }
}

class StockListScreen extends StatefulWidget {
  const StockListScreen({super.key});

  @override
  State<StockListScreen> createState() => _StockListScreenState();
}

class _StockListScreenState extends State<StockListScreen> {
  List<Map<String, dynamic>> _stock = [];
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refreshStock();
  }

  void _refreshStock() async {
    final data = await DatabaseHelper.instance.getStockList(query: _search
