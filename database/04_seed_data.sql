-- =====================================================================
-- ClinicOS Sample Seed Data (No PII / No Real Patient Phone Numbers)
-- =====================================================================

INSERT INTO public.clinics (id, name, timezone, settings)
VALUES (
  '5b201616-fdf0-4a37-8863-bd050ea90376',
  'عيادة ClinicOS التخصصية',
  'Asia/Riyadh',
  jsonb_build_object(
    'whatsapp_phone_number_id', 'YOUR_META_PHONE_NUMBER_ID',
    'slot_step_minutes', 30,
    'min_notice_minutes', 60,
    'max_days_ahead', 30,
    'reminder_hours_before', 24,
    'human_handoff_timeout_hours', 12,
    'emergency_number', '997',
    'installments_available', false,
    'location', 'الرياض حي العليا طريق الملك فهد برج ميديكال بلازا الدور الثالث',
    'parking', 'موقف سيارات مجاني وخدمة صف السيارات Valet قدام البرج',
    'payment_methods', jsonb_build_array('كاش (نقداً)', 'مدى', 'فيزا أو ماستركارد', 'Apple Pay', 'التأمين الطبي المعتمد'),
    'messages', jsonb_build_object(
      'booking_confirmed', jsonb_build_object(
        'ar', 'خلاص تمام اتأكد حجزك لـ {{service}} مع {{doctor}} يوم {{date}} الساعة {{time}} ✅' || E'\n' || 'تنورنا بالسلامة إن شاء الله ولو احتجت أي حاجة أنا معاك في أي وقت',
        'en', 'Your {{service}} appointment with {{doctor}} is confirmed for {{date}} at {{time}} ✅'
      ),
      'booking_rescheduled', jsonb_build_object(
        'ar', 'خلاص تمام عدلتلك ميعاد {{service}} مع {{doctor}} للميعاد الجديد يوم {{date}} الساعة {{time}} ✅' || E'\n' || 'تنورنا بالسلامة إن شاء الله',
        'en', 'Your {{service}} appointment with {{doctor}} has been rescheduled to {{date}} at {{time}} ✅'
      ),
      'booking_cancelled', jsonb_build_object(
        'ar', 'خلاص تمام يا فندم تم إلغاء ميعاد {{service}} مع {{doctor}} يوم {{date}} الساعة {{time}} 👍' || E'\n' || 'وقت ما تحب تحجز ميعاد جديد في أي وقت ابعتلي بس',
        'en', 'Your {{service}} appointment with {{doctor}} on {{date}} at {{time}} has been cancelled 👍'
      ),
      'appointment_reminder', jsonb_build_object(
        'ar', 'تذكير بموعدك: {{service}} مع {{doctor}} بتاريخ {{date}} الساعة {{time}}. نتطلع لرؤيتك!',
        'en', 'Appointment reminder: {{service}} with {{doctor}} on {{date}} at {{time}}. We look forward to seeing you!'
      ),
      'post_visit_followup', jsonb_build_object(
        'ar', 'حمداً لله على سلامتك! نتمنى أن تكون زيارتك لـ {{service}} مع {{doctor}} كانت مريحة. لو عندك أي استفسار إحنا في خدمتك دائماً.',
        'en', 'We hope your {{service}} visit with {{doctor}} went well! Reply anytime if you have any questions.'
      ),
      'human_handoff_staff_alert', jsonb_build_object(
        'ar', '🔔 تنبيه استقبال العيادة: المريض {{patient_name}} ({{patient_phone}}) يحتاج لتدخل بشري.' || E'\n' || 'آخر رسالة: {{message}}',
        'en', '🔔 Clinic Reception Alert: Patient {{patient_name}} ({{patient_phone}}) needs human assistance.' || E'\n' || 'Last message: {{message}}'
      )
    )
  )
)
ON CONFLICT (id) DO NOTHING;

-- Sample Providers (Doctors)
INSERT INTO public.providers (id, clinic_id, name, specialty, active)
VALUES
  ('a2634639-04fd-4485-bb52-b00ac206976c', '5b201616-fdf0-4a37-8863-bd050ea90376', 'د. ليان الحربي', 'طب وتجميل الأسنان (Dentistry)', true),
  ('f9ab13a5-e4f6-4acb-9cc9-3ef580ef926d', '5b201616-fdf0-4a37-8863-bd050ea90376', 'د. سامي العتيبي', 'الأمراض الجلدية والليزر (Dermatology & Laser)', true)
ON CONFLICT (id) DO NOTHING;

-- Sample Services
INSERT INTO public.services (id, clinic_id, code, name_ar, name_en, duration_minutes, price, active)
VALUES
  ('4305027d-539f-4d21-b2bb-4be7d2c73816', '5b201616-fdf0-4a37-8863-bd050ea90376', 'DENTAL_CHECKUP', 'فحص الأسنان', 'Dental Checkup', 30, 150, true),
  ('288e9e39-23c1-40ee-b690-6de3ffb251e7', '5b201616-fdf0-4a37-8863-bd050ea90376', 'DENTAL_CLEANING', 'تنظيف الأسنان', 'Dental Cleaning', 30, 250, true),
  ('6a5885a0-cde6-4b46-a432-42b4728595b1', '5b201616-fdf0-4a37-8863-bd050ea90376', 'TEETH_WHITENING', 'تبييض الأسنان بالليزر', 'Laser Teeth Whitening', 45, 600, true),
  ('80cb5019-2f66-47a5-a176-c67e20065777', '5b201616-fdf0-4a37-8863-bd050ea90376', 'DERM_CONSULT', 'استشارة جلدية', 'Dermatology Consultation', 30, 200, true),
  ('f0556088-7287-4e55-b8dc-7b935834fef8', '5b201616-fdf0-4a37-8863-bd050ea90376', 'HYDRAFACIAL', 'جلسة نضارة البشرة (هيدرافيشل)', 'HydraFacial Skin Glow', 45, 350, true),
  ('0d1b6057-3dba-409f-abfc-f528f6bf1730', '5b201616-fdf0-4a37-8863-bd050ea90376', 'LASER_SESSION', 'جلسة ليزر', 'Laser Session', 45, 400, true)
ON CONFLICT (id) DO NOTHING;

-- Sample Provider-Service Mapping
INSERT INTO public.provider_services (clinic_id, provider_id, service_id)
VALUES
  ('5b201616-fdf0-4a37-8863-bd050ea90376', 'a2634639-04fd-4485-bb52-b00ac206976c', '4305027d-539f-4d21-b2bb-4be7d2c73816'),
  ('5b201616-fdf0-4a37-8863-bd050ea90376', 'a2634639-04fd-4485-bb52-b00ac206976c', '288e9e39-23c1-40ee-b690-6de3ffb251e7'),
  ('5b201616-fdf0-4a37-8863-bd050ea90376', 'a2634639-04fd-4485-bb52-b00ac206976c', '6a5885a0-cde6-4b46-a432-42b4728595b1'),
  ('5b201616-fdf0-4a37-8863-bd050ea90376', 'f9ab13a5-e4f6-4acb-9cc9-3ef580ef926d', '80cb5019-2f66-47a5-a176-c67e20065777'),
  ('5b201616-fdf0-4a37-8863-bd050ea90376', 'f9ab13a5-e4f6-4acb-9cc9-3ef580ef926d', 'f0556088-7287-4e55-b8dc-7b935834fef8'),
  ('5b201616-fdf0-4a37-8863-bd050ea90376', 'f9ab13a5-e4f6-4acb-9cc9-3ef580ef926d', '0d1b6057-3dba-409f-abfc-f528f6bf1730')
ON CONFLICT (clinic_id, provider_id, service_id) DO NOTHING;
