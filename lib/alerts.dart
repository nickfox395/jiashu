import 'dart:async';
import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'data.dart';
import 'sync.dart';

class Alerts {
  static final plugin = FlutterLocalNotificationsPlugin();
  static Future<void> init() async {
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('ic_bg_service_small'),
      ),
    );
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'letters',
        '家书新消息',
        description: '新消息声音、振动和横幅提醒',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'listening',
        '家书后台接收',
        importance: Importance.low,
      ),
    );
  }

  static Future<bool> permission() async =>
      await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission() ??
      false;
  static Future<void> incoming(int count) async {
    if (count <= 0) return;
    await plugin.show(
      100,
      '家书有新消息',
      '$count 条新消息或笔记更新，点击查看',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'letters',
          '家书新消息',
          importance: Importance.high,
          priority: Priority.high,
          icon: 'ic_bg_service_small',
          playSound: true,
          enableVibration: true,
          visibility: NotificationVisibility.private,
          category: AndroidNotificationCategory.message,
          autoCancel: true,
        ),
      ),
    );
  }

  static Future<void> authentication(
    Session session,
    Store store,
    SyncResult result,
  ) async {
    if (!result.requiresLogin) return;
    final notice = '${session.loginId}:${result.status}';
    if (await store.setting('authNotice') == notice) return;
    await plugin.show(
      101,
      '家书需要重新登录',
      result.status,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'letters',
          '家书新消息',
          importance: Importance.high,
          priority: Priority.high,
          visibility: NotificationVisibility.private,
          icon: 'ic_bg_service_small',
          autoCancel: true,
        ),
      ),
    );
    await store.set('authNotice', notice);
  }
}

Future<void> configureBackground() async {
  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundMain,
      autoStart: false,
      autoStartOnBoot: false,
      isForegroundMode: true,
      notificationChannelId: 'listening',
      initialNotificationTitle: '家书正在接收',
      initialNotificationContent: '约每 3 分钟检查一次，可在家书设置中停止',
      foregroundServiceNotificationId: 800,
      foregroundServiceTypes: [AndroidForegroundType.remoteMessaging],
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

@pragma('vm:entry-point')
void backgroundMain(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await Alerts.init();
  bool busy = false, stopped = false;
  Timer? timer;
  service.on('stop').listen((_) async {
    stopped = true;
    timer?.cancel();
    await service.stopSelf();
  });
  Future<void> tick() async {
    if (busy || stopped) return;
    busy = true;
    try {
      final session = await Vault.read();
      if (session == null) {
        stopped = true;
        timer?.cancel();
        await service.stopSelf();
        return;
      }
      final store = await Store.open(session.account);
      if (await store.setting('background') != '1') {
        stopped = true;
        timer?.cancel();
        await service.stopSelf();
        return;
      }
      final next = int.tryParse(await store.setting('nextSync') ?? '0') ?? 0;
      if (next > DateTime.now().millisecondsSinceEpoch) return;
      final recent = DateTime.tryParse(await store.setting('lastSync') ?? '');
      if (recent != null && DateTime.now().difference(recent).inSeconds < 25) {
        return;
      }
      final result = await SyncEngine(
        session,
        store,
        isActive: () => !stopped,
      ).run();
      if (stopped) return;
      await Alerts.authentication(session, store, result);
      await Alerts.incoming(result.incoming);
      service.invoke('updated', {
        'account': session.account,
        'incoming': result.incoming,
      });
      if (service is AndroidServiceInstance) {
        await service.setForegroundNotificationInfo(
          title: '家书正在接收',
          content: '${result.status} · 可在设置中停止',
        );
      }
    } catch (_) {
      if (service is AndroidServiceInstance && !stopped) {
        await service.setForegroundNotificationInfo(
          title: '家书连接异常',
          content: '请打开家书检查登录和网络',
        );
      }
    } finally {
      busy = false;
    }
  }

  service.on('sync').listen((_) => tick());
  timer = Timer.periodic(const Duration(minutes: 3), (_) => tick());
  await tick();
}
