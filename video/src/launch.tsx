import React, {useEffect, useMemo, useRef, useState} from 'react';
import {AbsoluteFill, Easing, cancelRender, continueRender, delayRender, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';

// A fast launch cut. Kinetic type carries the problem and the numbers; the synthetic stage carries
// the product scenes, sped up and punched in. Every stage scene is labelled as a preview.

type StageWindow = Window & {stage?: {ready?: Promise<boolean>; seekScene: (id: string, local: number, opts?: {playAfter?: number}) => void}};

export const FPS = 30;
const s = (sec: number) => Math.round(sec * FPS);

// Product beats: stage scene, when it starts in the cut, how long it runs, playback speed.
const SHOTS = [
  {id: 'messages', at: 15, len: 7, speed: 1.15, app: 'Messages', tone: 'casual', said: '“tell Leo I’m running ten late, order me the usual”'},
  {id: 'slack', at: 22, len: 7.5, speed: 1.3, app: 'Slack', tone: 'work', said: '“tell Priya the deck’s ready, pricing’s up front…”'},
  {id: 'gmail', at: 29.5, len: 10, speed: 1.35, app: 'Gmail', tone: 'a full reply, in your voice', said: '“tell Marcus it’s signed, blue chairs Thursday…”'},
  {id: 'notes', at: 39.5, len: 10, speed: 1.9, app: 'Notes', tone: 'rambling → structured', said: '“notes for Friday’s launch review, three things…”'},
] as const;
export const LAUNCH_SECONDS = 74;

const ink = '#f4efe6', dim = 'rgba(244,239,230,.55)', accent = '#ffb067', bg = '#0b0f1e';
const font = '"DM Sans", system-ui, sans-serif';

function Word({text, from, size = 120, color = ink, weight = 700, y = 0}: {text: string; from: number; size?: number; color?: string; weight?: number; y?: number}) {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const p = spring({frame: frame - from, fps, config: {damping: 14, stiffness: 160}});
  return <div style={{fontFamily: font, fontSize: size, fontWeight: weight, color, letterSpacing: '-0.03em', opacity: p, transform: `translateY(${(1 - p) * 60 + y}px) scale(${0.92 + p * 0.08})`, filter: `blur(${(1 - p) * 12}px)`}}>{text}</div>;
}

function Card({from, to, children}: {from: number; to: number; children: React.ReactNode}) {
  const frame = useCurrentFrame();
  if (frame < from || frame >= to) return null;
  const out = interpolate(frame, [to - 6, to], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return <AbsoluteFill style={{background: bg, alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 18, opacity: out, textAlign: 'center'}}>{children}</AbsoluteFill>;
}

function Count({from, to, start, end, fmt}: {from: number; to: number; start: number; end: number; fmt: (n: number) => string}) {
  const frame = useCurrentFrame();
  const v = interpolate(frame, [from, to], [start, end], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic)});
  return <>{fmt(v)}</>;
}

const clock = (n: number) => `${Math.floor(n / 60)}:${String(Math.floor(n % 60)).padStart(2, '0')}`;

function Race({from}: {from: number}) {
  const frame = useCurrentFrame();
  const t = (frame - from) / FPS;
  // Real-time race scaled 1:30 so 129 seconds of typing plays in 4.3 s; speech finishes at 1.2 s.
  const typed = Math.min(129, t * 30), spoken = Math.min(36, t * 30);
  const bar = (v: number, max: number, color: string, label: string, done: boolean) => <div style={{width: 1300}}>
    <div style={{display: 'flex', justifyContent: 'space-between', fontFamily: font, fontSize: 44, color: done ? ink : dim, marginBottom: 14}}><span>{label}</span><span style={{fontVariantNumeric: 'tabular-nums', fontWeight: 700}}>{clock(v)}</span></div>
    <div style={{height: 28, borderRadius: 14, background: 'rgba(255,255,255,.08)'}}><div style={{height: '100%', width: `${(v / max) * 100}%`, borderRadius: 14, background: color, boxShadow: done ? `0 0 40px ${color}` : 'none'}} /></div>
  </div>;
  const win = spring({frame: frame - from - s(4.6), fps: FPS, config: {damping: 12}});
  return <AbsoluteFill style={{background: bg, alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 60}}>
    <div style={{fontFamily: font, fontSize: 34, color: dim, letterSpacing: '.18em', textTransform: 'uppercase'}}>The same 86 words, from this demo</div>
    {bar(spoken, 129, accent, 'Saying it with Intention', spoken >= 36)}
    {bar(typed, 129, '#6b7bd6', 'Typing it at 40 wpm', typed >= 129)}
    <div style={{fontFamily: font, fontSize: 150, fontWeight: 800, color: accent, opacity: win, transform: `scale(${0.6 + win * 0.4})`, letterSpacing: '-0.04em'}}>3.6× faster</div>
  </AbsoluteFill>;
}

function Stage() {
  const frame = useCurrentFrame();
  const iframe = useRef<HTMLIFrameElement>(null);
  const [loaded, setLoaded] = useState(false);
  const t = frame / FPS;
  const shot = SHOTS.find(x => t >= x.at && t < x.at + x.len);
  const target = shot ? {id: shot.id, local: (t - shot.at) * shot.speed} : t >= 62 ? {id: 'ending', local: t - 62} : {id: 'title', local: 0};
  const handle = useMemo(() => delayRender(`launch ${frame}`, {timeoutInMilliseconds: 60000}), [frame]);
  useEffect(() => {
    if (!loaded) return;
    let cancelled = false;
    (async () => {
      const win = iframe.current?.contentWindow as StageWindow | null;
      if (!win?.stage) throw new Error('stage API missing');
      await win.stage.ready;
      win.stage.seekScene(target.id, target.local, {playAfter: shot ? 0.5 : Infinity});
      await new Promise<void>(r => win.requestAnimationFrame(() => win.requestAnimationFrame(() => r())));
      if (!cancelled) continueRender(handle);
    })().catch(cancelRender);
    return () => {cancelled = true; continueRender(handle);};
  }, [loaded, target.id, target.local, shot, handle]);

  // Punch-in: each shot starts slightly wide and pushes in; Gmail pushes further toward the compose box.
  const local = shot ? t - shot.at : 0;
  const push = shot ? interpolate(local, [0, shot.len], [1.0, shot.id === 'gmail' ? 1.22 : 1.1], {easing: Easing.inOut(Easing.cubic)}) : 1;
  const enter = shot ? spring({frame: Math.round(local * FPS), fps: FPS, config: {damping: 16}}) : 1;
  return <AbsoluteFill style={{background: bg}}>
    <AbsoluteFill style={{transform: `scale(${push * (0.96 + 0.04 * enter)})`, transformOrigin: shot?.id === 'gmail' ? '50% 70%' : '50% 50%', opacity: shot ? enter : 1}}>
      <iframe ref={iframe} title="Intention synthetic desktop" src={`${staticFile('stage/index.html')}?render=1`} onLoad={() => setLoaded(true)} style={{border: 0, width: '100%', height: '100%'}} />
    </AbsoluteFill>
    {shot && <Lower shot={shot} local={local} />}
  </AbsoluteFill>;
}

function Lower({shot, local}: {shot: typeof SHOTS[number]; local: number}) {
  const p = spring({frame: Math.round(local * FPS) - 4, fps: FPS, config: {damping: 15}});
  return <>
    <div style={{position: 'absolute', left: 56, top: 56, fontFamily: font, opacity: p, transform: `translateX(${(1 - p) * -40}px)`, background: 'rgba(11,15,30,.82)', padding: '18px 30px 20px', borderRadius: 24, backdropFilter: 'blur(8px)'}}>
      <div style={{fontSize: 64, fontWeight: 800, color: ink, textShadow: '0 4px 30px rgba(0,0,0,.45)', letterSpacing: '-0.03em'}}>{shot.app}</div>
      <div style={{fontSize: 30, color: accent, fontWeight: 600, textShadow: '0 2px 20px rgba(0,0,0,.5)'}}>{shot.tone}</div>
    </div>
    <div style={{position: 'absolute', right: 40, bottom: 34, fontFamily: font, fontSize: 22, color: 'rgba(255,255,255,.8)', background: 'rgba(0,0,0,.45)', padding: '8px 16px', borderRadius: 999}}>Product preview · synthetic data</div>
  </>;
}

export function Launch() {
  const frame = useCurrentFrame();
  const t = frame / FPS;
  const showStage = SHOTS.some(x => t >= x.at && t < x.at + x.len) || t >= 62;
  return <AbsoluteFill style={{background: bg}}>
    <Stage />
    {!showStage && <AbsoluteFill style={{background: bg}} />}

    <Card from={0} to={s(4)}>
      <Word text="You write all day." from={4} size={130} />
      <Word text="Replies. Follow-ups. Quick notes." from={s(1.4)} size={60} color={dim} weight={500} />
    </Card>
    <Card from={s(4)} to={s(8)}>
      <div style={{fontFamily: font, fontSize: 260, fontWeight: 800, color: accent, letterSpacing: '-0.05em', fontVariantNumeric: 'tabular-nums'}}><Count from={s(4)} to={s(5.6)} start={0} end={40} fmt={n => String(Math.round(n))} /></div>
      <Word text="messages a day, typed one key at a time" from={s(4.6)} size={56} color={ink} weight={500} />
    </Card>
    <Card from={s(8)} to={s(11.5)}>
      <Word text="You already know" from={s(8)} size={120} />
      <Word text="what you want to say." from={s(8.5)} size={120} color={accent} />
    </Card>
    <Card from={s(11.5)} to={s(15)}>
      <img src={staticFile('assets/intention-wordmark.svg')} style={{height: 210, filter: 'invert(1)', transform: `scale(${0.8 + 0.2 * spring({frame: frame - s(11.5), fps: FPS, config: {damping: 10}})})`}} />
      <Word text="Say it. It writes it like you would. Wherever you are." from={s(12.4)} size={50} color={dim} weight={500} />
    </Card>

    <Card from={s(49.5)} to={s(51.5)}>
      <Word text="Four apps. Four voices." from={s(49.5)} size={110} />
      <Word text="One key." from={s(50.1)} size={110} color={accent} />
    </Card>
    {t >= 51.5 && t < 58 && <Race from={s(51.5)} />}
    <Card from={s(58)} to={s(62)}>
      <Word text="Every reply. Every app." from={s(58)} size={110} />
      <Word text="Faster than your hands." from={s(58.6)} size={110} color={accent} />
      <Word text="40 short replies a day: 78 minutes a week back from typing alone" from={s(59.4)} size={40} color={dim} weight={500} />
    </Card>
    {t >= 62 && <AbsoluteFill style={{alignItems: 'center', justifyContent: 'flex-end', paddingBottom: 90}}>
      <Word text="intention-gray.vercel.app" from={s(64)} size={44} color="#1d2340" weight={600} />
    </AbsoluteFill>}
  </AbsoluteFill>;
}
