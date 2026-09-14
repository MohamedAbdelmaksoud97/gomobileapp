# جاهزية Google Play وApp Store

الكود مهيأ لإنتاج حزم المتاجر بهوية `com.gofitness.app`، اتصال HTTPS فقط، منع
نسخ بيانات Android الاحتياطي، واجهة هاتف عربية RTL، أيقونات GO، وإقرار عدم
استخدام تشفير غير معفى على iOS.

## Android

تم التحقق محليًا من بناء `app-debug.apk` وبناء `app-release.aab` بتاريخ 14
سبتمبر 2026. ملف APK موقّع بشهادة التطوير ويصلح للمعاينة، بينما ملف AAB الحالي
غير موقّع عمدًا ولن يقبله Google Play قبل إضافة مفتاح الرفع بالخطوات التالية.

1. أنشئ upload key واحفظه خارج المستودع.
2. انسخ `android/key.properties.example` إلى `android/key.properties` واكتب
   المسار وكلمات المرور الحقيقية. الملف والمفاتيح مستبعدة من Git.
3. ارفع رقم `version` في `pubspec.yaml` لكل إصدار.
4. نفّذ:

   ```bash
   flutter clean
   flutter pub get
   flutter test
   flutter build appbundle --release
   ```

5. ارفع `build/app/outputs/bundle/release/app-release.aab` إلى مسار Internal
   testing أولًا، ثم نفّذ اختبار تسجيل الدخول والدفع والحجز والإشعارات على جهاز
   حقيقي.

## iOS

يجب تنفيذ البناء على macOS مع Xcode وحساب Apple Developer:

```bash
flutter pub get
cd ios && pod install && cd ..
open ios/Runner.xcworkspace
flutter build ipa --release
```

اختر Team وProvisioning Profile، وثبّت Bundle ID النهائي قبل أول رفع. اختبر
الكاميرا واختيار الملفات والإشعارات على iPhone حقيقي، ثم ارفع الأرشيف إلى
TestFlight قبل المراجعة العامة.

## متطلبات خارج الكود قبل النشر العام

- رابط سياسة خصوصية ودعم وحذف الحساب، وبيانات Data Safety / App Privacy.
- صور المتجر العربية، وصف مختصر وكامل، تصنيف المحتوى وبيانات التواصل.
- حسابات مراجعة منفصلة لا تحتوي بيانات إنتاج حقيقية.
- تفعيل مزود push: مشروع Firebase وAPNs، مفاتيح المنصتين، وendpoint مسجل
  لربط device token بالحساب. التطبيق يعرض حاليًا إشعارات النظام أثناء عمله
  ويحتفظ بصندوق الإشعارات؛ الاستقبال في الخلفية لا يمكن تفعيله بأمان قبل توفير
  هذه البنية الخارجية.
- اختبار closed/internal track لخادم الإنتاج ومراقبة الأعطال قبل الإطلاق.

لا تُخزّن ملف `key.properties` أو `.jks` أو مفاتيح Firebase/APNs أو حسابات
المراجعة داخل Git.
