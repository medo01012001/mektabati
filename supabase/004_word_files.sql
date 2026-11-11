-- =====================================================================
--  مكتبتي — تحديث 004: الكتب بصيغة Word (.docx)
--  كيفاش: Supabase > SQL Editor > New snippet > نسخ هاد الملف كامل > Run
--  (يقدر يتعاود يتشغل بلا مشاكل)
-- =====================================================================

-- 1. نوع الملف ديال كل كتاب: pdf ولا docx
alter table public.books add column if not exists file_type text not null default 'pdf';
alter table public.books drop constraint if exists books_file_type_check;
alter table public.books add constraint books_file_type_check check (file_type in ('pdf', 'docx'));

-- 2. التخزين يقبل حتى ملفات Word (نفس الحماية ديال الـ PDF)
update storage.buckets
set allowed_mime_types = array[
  'application/pdf',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
]
where id = 'pdfs';
