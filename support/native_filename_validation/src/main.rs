mod filename;
use filename::{rules_for_directory, sanitize_for_directory, Rules};
use std::{fs, path::Path, time::{SystemTime, UNIX_EPOCH}};

fn write_case(directory: &Path, name: &str, label: &str) {
    let path = directory.join(name);
    fs::write(&path, label.as_bytes()).unwrap_or_else(|e| panic!("{label}: write {}: {e}", path.display()));
    assert_eq!(fs::read(&path).unwrap(), label.as_bytes(), "{label}: readback");
    println!("PASS {label}: utf8={} utf16={} name={name}", name.len(), name.encode_utf16().count());
}
fn main() {
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let root = std::env::temp_dir().join(format!("ls-name-{nonce}"));
    fs::create_dir_all(&root).unwrap();
    let run = || {
        let policy = rules_for_directory(&root);
        assert_eq!(policy.rules, Rules::current());
        assert!(policy.max_len > 20);
        println!("PLATFORM os={} root={} max_component_or_path={}", std::env::consts::OS, root.display(), policy.max_len);
        write_case(&root, "control.txt", "control");
        let japanese = "土曜のあさはほめるちゃん 20260926 ＃124「関西のいま気になるエリアのええところ“ほめるポイント＝ほめポ”を見つけながら、ぶらりするほっこりトークがたっぷりのほめぶら番組！今回は、“グラングリーン大阪”をぶらり！」.mp4";
        assert_eq!((japanese.len(), japanese.encode_utf16().count()), (314, 116));
        let actual = sanitize_for_directory(japanese, &root, None, false).unwrap();
        if cfg!(windows) {
            assert_eq!(actual, japanese, "reported Windows name must be unchanged");
        } else {
            assert!(actual.len() <= policy.max_len && actual.ends_with(".mp4"));
            assert_ne!(actual, japanese, "POSIX name must be shortened");
        }
        write_case(&root, &actual, "reported_japanese");
        let nested = root.join("not-yet-created").join("deeper");
        let nested_policy = rules_for_directory(&nested);
        assert_eq!(nested_policy.rules, Rules::current());
        if cfg!(windows) {
            let expected = policy.max_len.saturating_sub("not-yet-created\\deeper".encode_utf16().count() + 1);
            assert_eq!(nested_policy.max_len, expected);
        } else {
            assert_eq!(nested_policy.max_len, policy.max_len);
        }
        fs::create_dir_all(&nested).unwrap();
        let nested_actual = sanitize_for_directory(&"n".repeat(300), &nested, None, false).unwrap();
        write_case(&nested, &nested_actual, "missing_ancestor_deep_dir");
        let cap = policy.max_len;
        let at_max = format!("{}.mp4", "a".repeat(cap - 4));
        let original = sanitize_for_directory(&at_max, &root, None, false).unwrap();
        assert_eq!(original, at_max);
        write_case(&root, &original, "at_max_original");
        let numbered = sanitize_for_directory(&at_max, &root, Some(1), false).unwrap();
        assert!(numbered.ends_with(" (1).mp4"));
        assert_ne!(numbered, original);
        if cfg!(windows) { assert!(numbered.encode_utf16().count() <= cap); }
        else { assert!(numbered.len() <= cap); }
        write_case(&root, &numbered, "at_max_collision");
        let emoji = format!("{}😀.mp4", "e".repeat(cap.saturating_sub(5)));
        let emoji_name = sanitize_for_directory(&emoji, &root, None, false).unwrap();
        assert!(emoji_name.ends_with(".mp4"));
        assert!(emoji_name.is_char_boundary(emoji_name.len()));
        write_case(&root, &emoji_name, "surrogate_boundary");
    };
    let result = std::panic::catch_unwind(run);
    fs::remove_dir_all(&root).unwrap();
    result.unwrap();
}
