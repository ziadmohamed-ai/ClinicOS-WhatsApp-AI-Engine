# Dynamic Context-Aware Voice Note Transcription (`gpt-4o-transcribe`)

ClinicOS uses a state-aware prompt injected dynamically into OpenAI `gpt-4o-transcribe` based on the patient's current `pending_booking` state in Supabase:

## 1. Base Clinic Vocabulary Prompt
```text
رسالة صوتية قصيرة باللهجة المصرية أو السعودية من مريض لعيادة أسنان وجلدية. مفردات: المواعيد المتاحة، أحجز ميعاد، ألغي الميعاد، فحص الأسنان، تنظيف، تبييض، ليزر، هيدرافيشل، دكتورة ليان، دكتور سامي، بكام، تابي، تمارا، موقف سيارات.
```

## 2. When `pending_booking` Has Numbered Slots (1–5)
```text
المريض بيختار من قائمة مواعيد مرقمة من ١ لـ ٥. ردود متوقعة: عايز الموعد الأول، عايز الموعد التاني، عايز الميعاد التالت، الموعد الرابع، الموعد الخامس، رقم واحد، رقم اتنين، رقم تلاتة، رقم أربعة، رقم خمسة، خليني في التاني، الساعة عشرة، الساعة عشرة ونص، الساعة حداشر، الساعة حداشر ونص، الساعة اتناشر.
```

## 3. When `pending_booking.selected_slot` Is Waiting for Confirmation
```text
المريض اختار موعد وبيرد بالتأكيد أو الإلغاء. ردود متوقعة: تأكيد، أكد الحجز، خلاص تمام أكد الحجز، أيوة موافق احجزه، تمام، لا ألغيه، إلغاء، عايز موعد تاني.
```
