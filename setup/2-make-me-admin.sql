-- Run AFTER you have created your own account on the website.
-- Change the email if you signed up with a different one.
insert into public.admins (user_id)
select id from auth.users where lower(email) = lower('akumi070128@gmail.com')
on conflict do nothing;

-- Check: should return one row with your email.
select u.email, a.added_at from public.admins a join auth.users u on u.id = a.user_id;
