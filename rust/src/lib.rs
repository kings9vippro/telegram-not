// © 2026 Phan Anh Khoi (Yanbi). Owner @axzy_anhkhoi.
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};

#[derive(Deserialize)]
struct Payload { history: Vec<Roll> }
#[derive(Clone, Deserialize)]
struct Roll { phien: String, xuc_xac: [u8; 3], ket_qua: String }
#[derive(Serialize)]
struct Recent { phien: String, ket_qua: String, xuc_xac: [u8; 3] }
#[derive(Serialize)]
struct Replay { phien: String, du_doan: String, ket_qua: String, status: String }
#[derive(Serialize)]
struct PatternStat { name: String, tai: usize, xiu: usize }
#[derive(Serialize)]
struct Output {
    total: usize, tai: usize, xiu: usize, bao: usize,
    faces: [usize; 6], sums: [usize; 19],
    streak: usize, streak_side: String, next: String,
    prediction: String, confidence: usize, pattern: String,
    tested: usize, model_accuracy: f64, baseline_accuracy: f64,
    recent: Vec<Recent>, replay: Vec<Replay>, patterns: Vec<PatternStat>,
}
fn valid_side(roll: &Roll) -> Option<char> {
    if roll.xuc_xac.iter().any(|x| !(1..=6).contains(x)) { return None; }
    let sum: u8 = roll.xuc_xac.iter().sum();
    let expected = if roll.xuc_xac.iter().all(|x| *x == roll.xuc_xac[0]) { 'B' }
        else if sum > 10 { 'T' } else { 'X' };
    let actual = match roll.ket_qua.as_str() { "Tài" => 'T', "Xỉu" => 'X', "Bão" => 'B', _ => return None };
    (expected == actual).then_some(actual)
}
fn label(side: char) -> &'static str { match side { 'T' => "Tài", 'X' => "Xỉu", _ => "Bão" } }
fn opposite(side: char) -> char { if side == 'T' { 'X' } else { 'T' } }
fn context_keys(tail: &str, prev: &Roll) -> Vec<String> {
    if tail.is_empty() { return vec![]; }
    let mut keys = Vec::new();
    let last = tail.chars().last().unwrap();
    let run = tail.chars().rev().take_while(|&c| c == last).count();
    keys.push(format!("Bệt {}", run.min(8)));
    for size in 1..=tail.len().min(8) {
        keys.push(format!("Nhịp {}", &tail[tail.len() - size..]));
    }
    if tail.len() >= 4 && tail.chars().rev().take(4).enumerate().all(|(i, c)| c == if i % 2 == 0 { last } else { opposite(last) }) {
        keys.push("Cầu 1–1".into());
    }
    for period in [3, 4, 6] {
        if tail.len() < period * 2 { continue; }
        let chunk = &tail[tail.len() - period..];
        if &tail[tail.len() - 2 * period..tail.len() - period] != chunk { continue; }
        let pattern = if period == 3 && chunk.as_bytes()[0] != chunk.as_bytes()[1] && chunk.as_bytes()[1] == chunk.as_bytes()[2] {
            "Cầu 1–2"
        } else if period == 3 && chunk.as_bytes()[0] == chunk.as_bytes()[1] && chunk.as_bytes()[1] != chunk.as_bytes()[2] {
            "Cầu 2–1"
        } else if period == 4 && chunk.as_bytes()[0] == chunk.as_bytes()[1] && chunk.as_bytes()[2] == chunk.as_bytes()[3] && chunk.as_bytes()[1] != chunk.as_bytes()[2] {
            "Cầu 2–2"
        } else if period == 6 && chunk[..3].bytes().all(|c| c == chunk.as_bytes()[0]) && chunk[3..].bytes().all(|c| c == chunk.as_bytes()[3]) && chunk.as_bytes()[0] != chunk.as_bytes()[3] {
            "Cầu 3–3"
        } else { continue };
        keys.push(pattern.into());
    }
    let sum: u8 = prev.xuc_xac.iter().sum();
    keys.push(format!("Tổng {sum}"));
    let doubles = prev.xuc_xac[0] == prev.xuc_xac[1] || prev.xuc_xac[1] == prev.xuc_xac[2] || prev.xuc_xac[0] == prev.xuc_xac[2];
    if doubles { keys.push("Xúc xắc trùng mặt".into()); }
    keys
}
fn estimate(keys: &[String], counts: &HashMap<String, (usize, usize)>, prior: f64) -> (f64, String) {
    let mut options: Vec<_> = keys.iter().filter_map(|key| {
        let &(n, t) = counts.get(key)?;
        if n < 20 { return None; }
        let p = (t as f64 + prior * 64.0) / (n as f64 + 64.0);
        Some((key.as_str(), p, n))
    }).collect();
    options.sort_by(|a, b| {
        let score = |p: f64, n: usize| (p - prior).abs() * (n as f64 / (n as f64 + 100.0));
        score(b.1, b.2).total_cmp(&score(a.1, a.2))
    });
    match options.first() {
        Some((name, probability, _)) => (*probability, (*name).to_owned()),
        None => (prior, "Tần suất chung".into()),
    }
}
fn analyze(input: &str) -> Result<Output, String> {
    let payload: Payload = serde_json::from_str(input).map_err(|_| "Dữ liệu API không hợp lệ")?;
    let mut rows: Vec<_> = payload.history.into_iter().filter_map(|roll| {
        let id = roll.phien.parse::<u64>().ok()?;
        valid_side(&roll)?;
        Some((id, roll))
    }).collect();
    rows.sort_by_key(|(id, _)| *id);
    rows.dedup_by_key(|(id, _)| *id);
    let mut out = Output { total: 0, tai: 0, xiu: 0, bao: 0, faces: [0; 6], sums: [0; 19],
        streak: 0, streak_side: String::new(), next: String::new(), prediction: "Đang chờ".into(),
        confidence: 0, pattern: String::new(), tested: 0, model_accuracy: 0.0,
        baseline_accuracy: 0.0, recent: vec![], replay: vec![], patterns: vec![] };
    let mut tail = String::new();
    let mut counts: HashMap<String, (usize, usize)> = HashMap::new();
    let mut model_wins = 0;
    let mut baseline_wins = 0;
    let mut last: Option<(u64, &Roll)> = None;
    let test_start = rows.len() * 3 / 5;
    for (index, (id, roll)) in rows.iter().enumerate() {
        let code = valid_side(roll).unwrap();
        let adjacent = last.is_some_and(|(previous_id, _)| *id == previous_id + 1);
        let keys = if adjacent { context_keys(&tail, last.unwrap().1) } else { vec![] };
        let prior = (out.tai as f64 + 24.0) / (out.tai + out.xiu + 48) as f64;
        let (prob, _) = estimate(&keys, &counts, prior);
        if index >= test_start && out.tai + out.xiu >= 100 && !keys.is_empty() && code != 'B' {
            out.tested += 1;
            model_wins += usize::from((prob >= 0.5) == (code == 'T'));
            baseline_wins += usize::from((prior >= 0.5) == (code == 'T'));
            if index + 30 >= rows.len() {
                out.replay.push(Replay { phien: roll.phien.clone(),
                    du_doan: label(if prob >= 0.5 { 'T' } else { 'X' }).into(),
                    ket_qua: roll.ket_qua.clone(),
                    status: if (prob >= 0.5) == (code == 'T') { "Thắng" } else { "Thua" }.into() });
            }
        }
        if code != 'B' {
            for key in keys {
                let entry = counts.entry(key).or_insert((0, 0));
                entry.0 += 1;
                entry.1 += usize::from(code == 'T');
            }
        }
        out.total += 1;
        match code { 'T' => out.tai += 1, 'X' => out.xiu += 1, _ => out.bao += 1 }
        let sum: usize = roll.xuc_xac.iter().map(|x| *x as usize).sum();
        out.sums[sum] += 1;
        for face in roll.xuc_xac { out.faces[(face - 1) as usize] += 1; }
        if !adjacent || code == 'B' { tail.clear(); out.streak = 0; }
        if code != 'B' {
            out.streak = if tail.ends_with(code) { out.streak + 1 } else { 1 };
            tail.push(code);
            if tail.len() > 8 { tail.remove(0); }
            out.streak_side = label(code).into();
        } else { out.streak_side.clear(); }
        out.next = (id + 1).to_string();
        if index + 40 >= rows.len() {
            out.recent.push(Recent { phien: roll.phien.clone(), ket_qua: roll.ket_qua.clone(), xuc_xac: roll.xuc_xac });
        }
        last = Some((*id, roll));
    }
    if out.tested > 0 {
        out.model_accuracy = 100.0 * model_wins as f64 / out.tested as f64;
        out.baseline_accuracy = 100.0 * baseline_wins as f64 / out.tested as f64;
    }
    if let Some((_, previous)) = last {
        let prior = (out.tai as f64 + 24.0) / (out.tai + out.xiu + 48) as f64;
        let (prob, name) = estimate(&context_keys(&tail, previous), &counts, prior);
        if out.total >= 100 {
            out.prediction = label(if prob >= 0.5 { 'T' } else { 'X' }).into();
            out.confidence = (100.0 * prob.max(1.0 - prob)).round() as usize;
            out.pattern = name;
        }
        let keys = context_keys(&tail, previous);
        out.patterns = keys.into_iter().filter_map(|name| {
            let &(n, t) = counts.get(&name)?;
            (n >= 8).then_some(PatternStat { name, tai: t, xiu: n - t })
        }).collect();
        out.patterns.sort_by(|a, b| (b.tai + b.xiu).cmp(&(a.tai + a.xiu)));
        out.patterns.truncate(8);
    }
    Ok(out)
}
#[no_mangle]
pub extern "C" fn yanbi_analyze(ptr: *const c_char) -> *mut c_char {
    if ptr.is_null() { return std::ptr::null_mut(); }
    let input = unsafe { CStr::from_ptr(ptr) }.to_string_lossy();
    let result = std::panic::catch_unwind(|| analyze(&input))
        .unwrap_or_else(|_| Err("Không thể phân tích dữ liệu".into()))
        .and_then(|out| serde_json::to_string(&out).map_err(|e| e.to_string()))
        .unwrap_or_else(|message| serde_json::json!({"error":message}).to_string());
    CString::new(result).unwrap().into_raw()
}
#[no_mangle]
pub extern "C" fn yanbi_free(ptr: *mut c_char) {
    if !ptr.is_null() { unsafe { drop(CString::from_raw(ptr)); } }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_invalid_roll_and_respects_storms() {
        let payload = serde_json::json!({"history":[
            {"phien":"1","xuc_xac":[3,3,3],"ket_qua":"Bão"},
            {"phien":"2","xuc_xac":[6,4,1],"ket_qua":"Tài"},
            {"phien":"3","xuc_xac":[2,2,2],"ket_qua":"Xỉu"},
            {"phien":"4","xuc_xac":[1,1,2],"ket_qua":"Xỉu"}
        ]});
        let output = analyze(&payload.to_string()).unwrap();
        assert_eq!((output.total, output.bao, output.tai, output.xiu), (3, 1, 1, 1));
        assert_eq!(output.next, "5");
        assert_eq!(output.streak, 1);
    }

    #[test]
    fn detects_repeated_patterns_without_future_results() {
        let outcomes: Vec<_> = (0..300).map(|i| {
            let tai = i % 2 == 0;
            serde_json::json!({"phien":(i+1).to_string(),
                "xuc_xac": if tai { [6,4,1] } else { [1,2,3] },
                "ket_qua": if tai { "Tài" } else { "Xỉu" }})
        }).collect();
        let output = analyze(&serde_json::json!({"history":outcomes}).to_string()).unwrap();
        assert_eq!(output.total, 300);
        assert!(output.tested >= 100);
        assert!(output.patterns.iter().any(|p| p.name == "Cầu 1–1"));
        assert_eq!(output.replay.len(), 30);
    }
}
