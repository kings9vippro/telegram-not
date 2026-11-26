// © 2026 Phan Anh Khoi (Yanbi). Owner @axzy_anhkhoi.
use serde::{Deserialize, Serialize};
use std::ffi::{c_char, CStr, CString};

#[derive(Deserialize)]
struct ApiData {
    history: Vec<Roll>,
}
#[derive(Clone, Deserialize)]
struct Roll {
    phien: String,
    xuc_xac: [u8; 3],
    ket_qua: String,
}
#[derive(Serialize)]
struct Output {
    total: usize,
    tai: usize,
    xiu: usize,
    bao: usize,
    faces: [usize; 6],
    sums: [usize; 19],
    streak: usize,
    streak_side: String,
    next: String,
    prediction: String,
    confidence: usize,
    tested: usize,
    model_accuracy: f64,
    baseline_accuracy: f64,
}
fn side(roll: &Roll) -> Option<char> {
    if roll.xuc_xac.iter().any(|&x| !(1..=6).contains(&x)) { return None; }
    let sum: u8 = roll.xuc_xac.iter().sum();
    let expected = if roll.xuc_xac.iter().all(|&x| x == roll.xuc_xac[0]) {
        'B'
    } else if sum > 10 { 'T' } else { 'X' };
    let actual = match roll.ket_qua.as_str() { "Tài" => 'T', "Xỉu" => 'X', "Bão" => 'B', _ => return None };
    (actual == expected).then_some(actual)
}
fn analyze(input: &str) -> Result<Output, String> {
    let payload: ApiData = serde_json::from_str(input).map_err(|_| "Dữ liệu API không hợp lệ")?;
    let mut rows: Vec<_> = payload.history.into_iter().filter_map(|roll| {
        let id = roll.phien.parse::<u64>().ok()?;
        Some((id, roll))
    }).collect();
    rows.sort_by_key(|(id, _)| *id);
    rows.dedup_by_key(|(id, _)| *id);
    let mut output = Output { total: 0, tai: 0, xiu: 0, bao: 0, faces: [0; 6], sums: [0; 19],
        streak: 0, streak_side: String::new(), next: String::new(), prediction: "Bỏ qua".into(),
        confidence: 0, tested: 0, model_accuracy: 0.0, baseline_accuracy: 0.0 };
    let mut tail = String::new();
    let mut counts = std::collections::HashMap::<String, (usize, usize)>::new();
    let mut model_wins = 0;
    let mut baseline_wins = 0;
    let mut model_loss = 0.0;
    let mut baseline_loss = 0.0;
    let mut last_id = 0;
    let mut previous_roll: Option<&Roll> = None;
    let test_start = rows.len() * 3 / 5;
    for (index, (id, roll)) in rows.iter().enumerate() {
        let Some(code) = side(roll) else { continue };
        let adjacent = *id == last_id + 1;
        if !adjacent || code == 'B' { tail.clear(); output.streak = 0; }
        let prior = (output.tai as f64 + 24.0) / (output.tai + output.xiu + 48) as f64;
        let keys = if adjacent && !tail.is_empty() { context_keys(&tail, previous_roll) } else { vec![] };
        let (prob, support) = estimate(&keys, &counts, prior);
        if code != 'B' && index >= test_start && output.tai + output.xiu >= 100 && !keys.is_empty() {
            let actual = if code == 'T' { 1.0 } else { 0.0 };
            output.tested += 1;
            model_wins += usize::from((prob >= 0.5) == (code == 'T'));
            baseline_wins += usize::from((prior >= 0.5) == (code == 'T'));
            model_loss += (prob - actual).powi(2);
            baseline_loss += (prior - actual).powi(2);
        }
        if code != 'B' {
            for key in keys {
                let entry = counts.entry(key).or_insert((0, 0));
                entry.0 += 1;
                entry.1 += usize::from(code == 'T');
            }
        }
        output.total += 1;
        match code { 'T' => output.tai += 1, 'X' => output.xiu += 1, _ => output.bao += 1 }
        let sum: usize = roll.xuc_xac.iter().map(|x| *x as usize).sum();
        output.sums[sum] += 1;
        for face in roll.xuc_xac { output.faces[(face - 1) as usize] += 1; }
        if code != 'B' {
            output.streak = if tail.ends_with(code) { output.streak + 1 } else { 1 };
            tail.push(code);
            if tail.len() > 9 { tail.remove(0); }
            output.streak_side = if code == 'T' { "Tài" } else { "Xỉu" }.into();
        } else { output.streak_side.clear(); }
        output.next = (id + 1).to_string();
        last_id = *id;
        previous_roll = Some(roll);
        let _ = support;
    }
    if output.tested > 0 {
        output.model_accuracy = model_wins as f64 * 100.0 / output.tested as f64;
        output.baseline_accuracy = baseline_wins as f64 * 100.0 / output.tested as f64;
    }
    if let Some((_, last)) = rows.last() {
        let prior = (output.tai as f64 + 24.0) / (output.tai + output.xiu + 48) as f64;
        let (prob, support) = estimate(&context_keys(&tail, Some(last)), &counts, prior);
        let confidence = prob.max(1.0 - prob);
        if output.tested >= 200 && model_loss < baseline_loss &&
            model_wins >= baseline_wins + (output.tested as f64 * 0.02).ceil() as usize &&
            support >= 24 && confidence >= 0.56 {
            output.prediction = if prob >= 0.5 { "Tài" } else { "Xỉu" }.into();
            output.confidence = (confidence * 100.0).round() as usize;
        }
    }
    Ok(output)
}
fn context_keys(tail: &str, previous: Option<&Roll>) -> Vec<String> {
    if tail.is_empty() { return vec![]; }
    let mut keys = Vec::new();
    let last = tail.chars().last().unwrap();
    let run = tail.chars().rev().take_while(|&c| c == last).count().min(5);
    keys.push(format!("run:{last}:{run}"));
    if let Some(prev) = previous { keys.push(format!("sum:{}", prev.xuc_xac.iter().map(|&x| x as usize).sum::<usize>())); }
    for size in 2..=4.min(tail.len()) { keys.push(format!("suffix:{}", &tail[tail.len() - size..])); }
    keys
}
fn estimate(keys: &[String], counts: &std::collections::HashMap<String, (usize, usize)>, prior: f64) -> (f64, usize) {
    let (mut adjust, mut groups, mut support) = (0.0, 0, 0);
    for key in keys {
        if let Some(&(n, t)) = counts.get(key) {
            if n < 24 { continue; }
            adjust += (t as f64 - n as f64 * prior) / (n + 48) as f64;
            groups += 1;
            support = support.max(n);
        }
    }
    (prior + if groups > 0 { adjust / groups as f64 } else { 0.0 }, support)
}
#[no_mangle]
pub extern "C" fn yanbi_analyze(ptr: *const c_char) -> *mut c_char {
    if ptr.is_null() { return std::ptr::null_mut(); }
    let input = unsafe { CStr::from_ptr(ptr) }.to_string_lossy();
    let result = analyze(&input).and_then(|out| serde_json::to_string(&out).map_err(|e| e.to_string()))
        .unwrap_or_else(|message| serde_json::json!({"error":message}).to_string());
    CString::new(result).unwrap().into_raw()
}
#[no_mangle]
pub extern "C" fn yanbi_free(ptr: *mut c_char) {
    if !ptr.is_null() { unsafe { drop(CString::from_raw(ptr)); } }
}
