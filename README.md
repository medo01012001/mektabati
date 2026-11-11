# 📚 مكتبتي

مكتبة شخصية أونلاين: ترفع كتب PDF، تلقاها من أي جهاز، وتشاركها مع أصدقائك.

- الواجهة: `index.html` (HTML + Tailwind + pdf.js)
- السيرفر: [Supabase](https://supabase.com) (الحسابات، القاعدة، تخزين الملفات)
- قاعدة البيانات وقواعد الأمان: `supabase/schema.sql`

المفتاح اللي ف `index.html` هو *publishable key* ديال Supabase، عادي يكون عمومي.
الحماية ديال البيانات كاينة ف قواعد Row Level Security داخل `supabase/schema.sql`.
