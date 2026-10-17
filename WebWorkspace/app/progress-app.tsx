"use client";

import { useEffect, useRef, useState } from "react";
import { addUnit, deleteUnit, renameUnit, reorder, setCompleted, setPaused } from "../lib/content-progress/commands";
import { projectProgress } from "../lib/content-progress/projection";
import { BrowserProgressRepository, type ProgressDraft } from "../lib/content-progress/repository";
import type { ProgressProject } from "../lib/content-progress/domain";
import "./progress.css";

export function ProgressApp() {
  const [store, setStore] = useState<BrowserProgressRepository | null>(null);
  const [projects, setProjects] = useState<ProgressProject[]>([]);
  const [selectedID, setSelectedID] = useState<string | null>(null);
  const [draft, setDraft] = useState<ProgressDraft | null>(null);
  const [newTitle, setNewTitle] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const draftSaveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const operationPending = useRef(false);

  useEffect(() => {
    let cancelled = false;
    let opened: BrowserProgressRepository | null = null;
    BrowserProgressRepository.open().then(async (repository) => {
      opened = repository;
      const [savedProjects, savedDrafts] = await Promise.all([repository.projects(), repository.drafts()]);
      if (cancelled) { repository.close(); return; }
      setStore(repository);
      setProjects(savedProjects);
      setDraft(savedDrafts[0] ?? null);
      setLoading(false);
    }).catch((cause) => { if (!cancelled) { setError(String(cause)); setLoading(false); } });
    return () => { cancelled = true; opened?.close(); };
  }, []);

  useEffect(() => {
    if (!store || !draft) return;
    draftSaveTimer.current = setTimeout(() => { store.saveDraft(draft).catch((cause) => setError(String(cause))); }, 200);
    return () => { if (draftSaveTimer.current) clearTimeout(draftSaveTimer.current); };
  }, [draft, store]);

  const selected = projects.find((project) => project.id === selectedID) ?? null;
  useEffect(() => {
    if (!selected) return;
    const currentID = projectProgress(selected).currentUnitID;
    if (currentID) document.getElementById(`progress-unit-${currentID}`)?.scrollIntoView({ block: "center" });
  }, [selected]);
  async function refresh() { if (store) setProjects(await store.projects()); }
  async function startDraft() {
    if (!store) return;
    if (draft) return;
    try {
      const saved = await store.drafts();
      if (saved[0]) { setDraft(saved[0]); return; }
    } catch (cause) { setError(String(cause)); return; }
    const timestamp = new Date().toISOString();
    const next: ProgressDraft = { id: crypto.randomUUID(), name: "", outlineText: "", courseURL: null, units: [], createdAt: timestamp, updatedAt: timestamp };
    try { await store.saveDraft(next); setDraft(next); setError(""); } catch (cause) { setError(String(cause)); }
  }
  function editDraft(change: Partial<ProgressDraft>) {
    setDraft((current) => current ? { ...current, ...change, updatedAt: new Date().toISOString() } : null);
  }
  async function confirm() {
    if (!store || !draft) return;
    if (draftSaveTimer.current) clearTimeout(draftSaveTimer.current);
    try {
      await store.saveDraft(draft);
      const project = await store.confirmDraft(draft.id);
      await refresh(); setSelectedID(project.id); setDraft(null); setError("");
    } catch (cause) { setError(String(cause)); }
  }
  async function cancel() {
    if (!store || !draft) return;
    if (draftSaveTimer.current) clearTimeout(draftSaveTimer.current);
    try { await store.removeDraft(draft.id); setDraft(null); setError(""); } catch (cause) { setError(String(cause)); }
  }
  async function saveAndClose() {
    if (!store || !draft) return;
    if (draftSaveTimer.current) clearTimeout(draftSaveTimer.current);
    try { await store.saveDraft(draft); setDraft(null); setError(""); }
    catch (cause) { setError(String(cause)); }
  }
  async function run(change: () => ProgressProject): Promise<boolean> {
    if (!store || operationPending.current) return false;
    operationPending.current = true;
    try {
      const next = change();
      await store.saveProject(next);
      await refresh();
      setError("");
      return true;
    } catch (cause) {
      setError(String(cause));
      return false;
    } finally { operationPending.current = false; }
  }
  function move(id: string, direction: -1 | 1) {
    if (!selected) return;
    const ids = selected.units.map((unit) => unit.id);
    const index = ids.indexOf(id), target = index + direction;
    if (target < 0 || target >= ids.length) return;
    [ids[index], ids[target]] = [ids[target], ids[index]];
    void run(() => reorder(selected, ids));
  }
  function dropUnit(sourceID: string, destinationID: string) {
    if (!selected || sourceID === destinationID) return;
    const ids = selected.units.map((unit) => unit.id);
    const source = ids.indexOf(sourceID), destination = ids.indexOf(destinationID);
    if (source < 0 || destination < 0) return;
    ids.splice(destination, 0, ids.splice(source, 1)[0]);
    void run(() => reorder(selected, ids));
  }
  function moveDraftUnit(id: string, direction: -1 | 1) {
    if (!draft) return;
    const units = [...draft.units];
    const index = units.findIndex((unit) => unit.id === id);
    const target = index + direction;
    if (target < 0 || target >= units.length) return;
    [units[index], units[target]] = [units[target], units[index]];
    editDraft({ units });
  }

  if (loading) return <main className="progress-shell">正在读取本地项目…</main>;
  if (!store) return <main className="progress-shell"><p role="alert">无法打开本地项目：{error}</p></main>;
  return <main className="progress-shell">
    <header><div><small>SELF STUDY STUDIO</small><h1>学习内容进度</h1></div><span>仅保存在此浏览器</span></header>
    {error && <p role="alert" className="progress-error">{error}</p>}
    {selected ? <section aria-label="项目详情">
      <button className="progress-link" onClick={() => setSelectedID(null)}>← 返回项目</button>
      <div className="progress-row"><div><small>{selected.isPaused ? "已暂停" : "进行中"}</small><h2>{selected.name}</h2></div>
        <button onClick={() => void run(() => setPaused(selected, !selected.isPaused))}>{selected.isPaused ? "恢复项目" : "暂停项目"}</button></div>
      <Summary project={selected} />
      <h3>学习单元</h3>
      {selected.units.length === 0 && <p>尚无学习单元，先添加第一项。</p>}
      <ol className="progress-units">{selected.units.map((unit, index) => <li key={unit.id} id={`progress-unit-${unit.id}`} draggable
        onDragStart={(event) => event.dataTransfer.setData("text/plain", unit.id)}
        onDragOver={(event) => event.preventDefault()}
        onDrop={(event) => { event.preventDefault(); dropUnit(event.dataTransfer.getData("text/plain"), unit.id); }}>
        <label><input type="checkbox" checked={unit.isCompleted} disabled={selected.isPaused} onChange={(event) => void run(() => setCompleted(selected, unit.id, event.target.checked))} />{unit.title}</label>
        <div><button aria-label={`上移 ${unit.title}`} disabled={index === 0} onClick={() => move(unit.id, -1)}>↑</button>
          <button aria-label={`下移 ${unit.title}`} disabled={index === selected.units.length - 1} onClick={() => move(unit.id, 1)}>↓</button>
          <button onClick={() => { const title = window.prompt("修改学习单元", unit.title); if (title !== null) void run(() => renameUnit(selected, unit.id, title)); }}>修改</button>
          <button onClick={() => { if (window.confirm(`删除「${unit.title}」及其完成状态？`)) void run(() => deleteUnit(selected, unit.id)); }}>删除</button></div>
      </li>)}</ol>
      <div className="progress-add"><input aria-label="新学习单元标题" placeholder="添加学习单元" value={newTitle} onChange={(event) => setNewTitle(event.target.value)} />
        <button disabled={!newTitle.trim()} onClick={() => { void run(() => addUnit(selected, newTitle)).then((saved) => { if (saved) setNewTitle(""); }); }}>添加</button></div>
    </section> : <section aria-label="项目首页">
      <div className="progress-row"><div><small>YOUR PROJECTS</small><h2>从上次的位置继续</h2></div><button className="progress-primary" onClick={() => void startDraft()}>创建项目</button></div>
      {projects.length === 0 && <div className="progress-empty"><p>还没有学习项目。</p><button onClick={() => void startDraft()}>创建第一个项目</button></div>}
      <div className="progress-cards">{projects.map((project) => <button className="progress-card" key={project.id} onClick={() => setSelectedID(project.id)}>
        <small>{project.isPaused ? "已暂停" : "学习项目"}</small><strong>{project.name}</strong><Summary project={project} /><span>查看项目 →</span>
      </button>)}</div>
    </section>}
    {draft && <div className="progress-overlay"><div role="dialog" aria-modal="true" aria-label="创建学习项目" className="progress-dialog">
      <small>NEW PROJECT</small><h2>创建学习项目</h2>
      <label>项目名称<input autoFocus placeholder="例如：学习 React" value={draft.name} onChange={(event) => editDraft({ name: event.target.value })} /></label>
      <p>当前可手动建立内容结构；AI 初始化将在下一阶段接入。</p>
      <h3>学习单元</h3><ol>{draft.units.map((unit, index) => <li key={unit.id}><input aria-label={`第 ${index + 1} 个单元标题`} value={unit.title} onChange={(event) => editDraft({ units: draft.units.map((item) => item.id === unit.id ? { ...item, title: event.target.value } : item) })} /><button aria-label={`上移第 ${index + 1} 个单元`} disabled={index === 0} onClick={() => moveDraftUnit(unit.id, -1)}>↑</button><button aria-label={`下移第 ${index + 1} 个单元`} disabled={index === draft.units.length - 1} onClick={() => moveDraftUnit(unit.id, 1)}>↓</button><button onClick={() => editDraft({ units: draft.units.filter((item) => item.id !== unit.id) })}>删除</button></li>)}</ol>
      <button onClick={() => editDraft({ units: [...draft.units, { id: crypto.randomUUID(), title: "" }] })}>添加单元</button>
      <div className="progress-dialog-actions"><button onClick={() => void cancel()}>取消</button><button onClick={() => void saveAndClose()}>保存草稿并返回</button><button className="progress-primary" disabled={!draft.name.trim() || draft.units.some((unit) => !unit.title.trim())} onClick={() => void confirm()}>确认创建</button></div>
    </div></div>}
    <footer><a href="/legacy">查看旧版学习记录</a></footer>
  </main>;
}

function Summary({ project }: { project: ProgressProject }) {
  const value = projectProgress(project);
  const current = project.units.find((unit) => unit.id === value.currentUnitID);
  const next = project.units.find((unit) => unit.id === value.nextUnitID);
  return <div className="progress-summary"><div><strong>{value.percentage}%</strong> <span>{value.completed} / {value.total} 已完成</span></div>
    <div className="progress-meter" role="progressbar" aria-label={`${project.name} 完成进度`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={value.percentage}><span style={{ width: `${value.percentage}%` }} /></div>
    <p>当前：{current?.title ?? (value.isAllCompleted ? "全部完成" : "尚无学习单元")}</p><p>下一单元：{next?.title ?? "无下一单元"}</p>
  </div>;
}
