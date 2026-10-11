import React, {useEffect, useMemo, useRef, useState} from 'react';
import {AbsoluteFill, Audio, Easing, Img, cancelRender, continueRender, delayRender, interpolate, spring, staticFile, useCurrentFrame} from 'remotion';
import cut from './cut.json';

// Launch cut, structured like the reference: a typed hook, one-beat type cards, floating real UI,
// the product moment in four apps, the proof, the wordmark. Every cut lands on a beat of the track.

export const FPS3 = 30;
const BEAT = 60 / cut.bpm;                         // seconds per beat
const b = (n: number) => Math.round((cut.firstBeat + n * BEAT) * FPS3) - Math.round(cut.firstBeat * FPS3);
const paper = '#F9FAF7', ink = '#202A2E', dot = '#EE5F27', mute = 'rgba(32,42,46,.5)';
const sf = '"SF Pro Display", -apple-system, system-ui, sans-serif';
const serif = '"Bree Serif", serif';
const css = `@font-face{font-family:"Bree Serif";src:url(${staticFile('v2/BreeSerif-Regular.woff2')}) format("woff2");}`;
const pop = (frame: number, damping = 14, stiffness = 190) => spring({frame, fps: FPS3, config: {damping, stiffness}});
const land = `url(${staticFile('v2/intention-landscape-approved.webp')}) center/cover`;

// Timeline in beats.
const T = {
  hook: 0, write: 6, apps: 8, ai: 10, say: 15,
  messages: 18, slack: 30, gmail: 42, notes: 58,
  all: 68, learns: 80, voice: 84, race: 92, everyone: 98, model: 102, end: 110, done: 122,
};
export const LAUNCH3_FRAMES = b(T.done);

function Words({children, at, size = 200, color = ink, font = sf, weight = 700, delay = 0}: {children: React.ReactNode; at: number; size?: number; color?: string; font?: string; weight?: number; delay?: number}) {
  const p = pop(useCurrentFrame() - at - delay);
  return <div style={{fontFamily: font, fontWeight: weight, fontSize: size, color, letterSpacing: font === sf ? '-0.045em' : '-0.02em', lineHeight: 1, opacity: p, transform: `translateY(${(1 - p) * 90}px) scale(${0.96 + 0.04 * p})`, filter: `blur(${(1 - p) * 16}px)`}}>{children}</div>;
}

function Card({from, to, bg = paper, children}: {from: number; to: number; bg?: string; children: React.ReactNode}) {
  const frame = useCurrentFrame();
  if (frame < from || frame >= to) return null;
  return <AbsoluteFill style={{background: bg, alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 34, textAlign: 'center'}}>{children}</AbsoluteFill>;
}

const HOOK = 'hi marcus, sorry for the slow reply! just wanted to say that the lease is';
function Hook({from, to}: {from: number; to: number}) {
  const frame = useCurrentFrame();
  if (frame < from || frame >= to) return null;
  const l = frame - from;
  const raw = l * 0.3;
  const n = raw < 30 ? raw : raw < 36 ? 30 : raw < 40 ? 30 - (raw - 36) : 26 + (raw - 40);
  const p = pop(l, 18);
  return <AbsoluteFill style={{background: paper, alignItems: 'center', justifyContent: 'center'}}>
    <div style={{width: 1320, borderRadius: 44, background: '#fff', padding: '48px 60px 44px', boxShadow: '0 50px 140px rgba(32,42,46,.18), 0 0 0 1px rgba(32,42,46,.06)', opacity: p, transform: `scale(${0.92 + 0.08 * p})`}}>
      <div style={{display: 'flex', alignItems: 'center', gap: 18, marginBottom: 26}}>
        <Img src={staticFile('v2/icons/mail.png')} style={{width: 56, height: 56}} />
        <div style={{fontFamily: sf, fontSize: 32, color: mute}}>Re: Oakland site, the lease</div>
      </div>
      <div style={{fontFamily: sf, fontSize: 64, fontWeight: 500, color: ink, minHeight: 170, lineHeight: 1.25, letterSpacing: '-0.02em'}}>{HOOK.slice(0, Math.floor(Math.max(0, n)))}<span style={{color: '#0a6fd6', opacity: Math.floor(frame / 8) % 2 ? 0 : 1}}>|</span></div>
    </div>
  </AbsoluteFill>;
}

const ICONS = ['messages', 'slack', 'mail', 'notes'];
const MORE = ['x', 'linkedin', 'whatsapp', 'gdocs', 'notion', 'substack', 'messages', 'discord', 'outlook', 'slack', 'mail', 'notes'];
const MORE_NAMES = ['x', 'linkedin', 'whatsapp', 'google docs', 'notion', 'substack', 'imessage', 'discord', 'outlook', 'slack', 'gmail', 'notes'];
// Every half beat another app lands; the name under the grid follows the latest one.
function Montage({at}: {at: number}) {
  const frame = useCurrentFrame();
  const half = Math.round(BEAT * FPS3 / 2);
  const shown = Math.min(MORE.length, Math.floor((frame - at) / half) + 1);
  return <>
    <div style={{display: 'grid', gridTemplateColumns: 'repeat(6, 200px)', gap: 48}}>{MORE.map((n, i) => {
      const p = pop(frame - at - i * half, 11, 220);
      return <Img key={i} src={staticFile(`v2/icons/${n}.png`)} style={{width: 200, height: 200, borderRadius: 44, objectFit: 'contain', opacity: p, transform: `scale(${0.5 + 0.5 * p}) translateY(${(1 - p) * 60}px)`, filter: 'drop-shadow(0 24px 34px rgba(32,42,46,.2))'}} />;
    })}</div>
    <div style={{fontFamily: sf, fontWeight: 700, fontSize: 130, letterSpacing: '-0.045em', color: ink, marginTop: 30}}>in <span style={{color: dot}}>{MORE_NAMES[shown - 1]}</span>.</div>
  </>;
}
function Icons({at}: {at: number}) {
  const frame = useCurrentFrame();
  return <div style={{display: 'flex', gap: 56}}>{ICONS.map((n, i) => {
    const p = pop(frame - at - i * 2, 11, 200);
    return <Img key={n} src={staticFile(`v2/icons/${n}.png`)} style={{width: 220, height: 220, opacity: p, transform: `translateY(${(1 - p) * 120}px) rotate(${(1 - p) * (i % 2 ? 12 : -12)}deg)`, filter: 'drop-shadow(0 30px 40px rgba(32,42,46,.22))'}} />;
  })}</div>;
}

type StageWindow = Window & {stage?: {ready?: Promise<boolean>; seekScene: (id: string, local: number, opts?: {playAfter?: number}) => void}};
const SHOTS = [
  {id: 'messages', from: T.messages, to: T.slack, speed: 1.15, icon: 'messages', line: 'to a friend', origin: '50% 62%', zoom: 1.28},
  {id: 'slack', from: T.slack, to: T.gmail, speed: 1.6, icon: 'slack', line: 'to the team', origin: '62% 66%', zoom: 1.22},
  {id: 'gmail', from: T.gmail, to: T.notes, speed: 1.2, icon: 'mail', line: 'to marcus', origin: '40% 80%', zoom: 1.3},
  {id: 'notes', from: T.notes, to: T.all, speed: 3.2, icon: 'notes', line: 'to yourself', origin: '50% 40%', zoom: 1.25},
];

// One stage iframe plays each app's real-time scene: the cue is heard word by word, then the
// words land at the cursor. The camera pushes toward the cursor as it writes.
function Live() {
  const frame = useCurrentFrame();
  const iframe = useRef<HTMLIFrameElement>(null);
  const [loaded, setLoaded] = useState(false);
  const shot = SHOTS.find(s => frame >= b(s.from) && frame < b(s.to));
  const local = shot ? ((frame - b(shot.from)) / FPS3) * shot.speed : 0;
  const id = shot?.id ?? 'messages';
  const handle = useMemo(() => delayRender(`live ${frame}`, {timeoutInMilliseconds: 60000}), [frame]);
  useEffect(() => {
    if (!loaded) return;
    let cancelled = false;
    (async () => {
      const win = iframe.current?.contentWindow as StageWindow | null;
      if (!win?.stage) throw new Error('stage API missing');
      await win.stage.ready;
      win.stage.seekScene(id, local, {playAfter: 0.25});
      await new Promise<void>(r => win.requestAnimationFrame(() => win.requestAnimationFrame(() => r())));
      if (!cancelled) continueRender(handle);
    })().catch(cancelRender);
    return () => {cancelled = true; continueRender(handle);};
  }, [loaded, id, local, handle]);
  const t = shot ? (frame - b(shot.from)) / FPS3 : 0;
  const len = shot ? (b(shot.to) - b(shot.from)) / FPS3 : 1;
  const zoom = shot ? interpolate(t, [0, len], [1.02, shot.zoom], {easing: Easing.inOut(Easing.cubic)}) : 1;
  const enter = shot ? pop(frame - b(shot.from), 18) : 0;
  const tag = shot ? pop(frame - b(shot.from) - 6, 13) : 0;
  return <AbsoluteFill style={{opacity: shot ? 1 : 0}}>
    <AbsoluteFill style={{transform: `scale(${zoom * (0.94 + 0.06 * enter)})`, transformOrigin: shot?.origin}}>
      <iframe ref={iframe} src={`${staticFile('stage/index.html')}?render=1`} onLoad={() => setLoaded(true)} style={{border: 0, width: '100%', height: '100%'}} />
    </AbsoluteFill>
    {shot && <div style={{position: 'absolute', left: 56, top: 56, display: 'flex', alignItems: 'center', gap: 24, padding: '20px 44px 20px 24px', background: paper, borderRadius: 40, boxShadow: '0 30px 80px rgba(20,30,40,.3)', opacity: tag, transform: `translateX(${(1 - tag) * -60}px)`}}>
      <Img src={staticFile(`v2/icons/${shot.icon}.png`)} style={{width: 112, height: 112}} />
      <div style={{fontFamily: sf, fontWeight: 700, fontSize: 88, letterSpacing: '-0.04em', color: ink}}>{shot.line}</div>
    </div>}
    {shot && <div style={{position: 'absolute', right: 34, bottom: 28, fontFamily: sf, fontSize: 20, color: 'rgba(255,255,255,.9)', background: 'rgba(32,42,46,.55)', padding: '7px 14px', borderRadius: 999}}>product preview · synthetic data</div>}
  </AbsoluteFill>;
}

function Float({src, at, w, x, y, rot, delay = 0}: {src: string; at: number; w: number; x: number; y: number; rot: number; delay?: number}) {
  const l = useCurrentFrame() - at - delay;
  const p = pop(l, 16, 150);
  return <Img src={staticFile(`v2/${src}.png`)} style={{position: 'absolute', width: w, left: `calc(50% + ${x}px)`, top: `calc(50% + ${y}px)`, borderRadius: 16, boxShadow: '0 60px 120px rgba(20,30,40,.35)', opacity: p,
    transform: `translate(-50%,-50%) perspective(2400px) rotateY(${rot * (1.6 - p) - l * 0.08}deg) rotateX(${8 - 4 * p}deg) translateY(${(1 - p) * 220}px)`}} />;
}

const VOICES = [
  ['leo', 'Leo', 'messages', 'running ten late. order me the usual, i’ll get this one'],
  ['priya', 'Priya', 'slack', 'Deck’s ready for 3. I moved pricing up front, and I’ll send it to the team right after lunch.'],
  ['marcus', 'Marcus', 'mail', 'Hi Marcus, signed and sent back. The blue chairs arrive Thursday. Thank you for holding the place through the summer.'],
];
function Voices({at}: {at: number}) {
  const frame = useCurrentFrame();
  return <div style={{display: 'flex', gap: 40}}>{VOICES.map(([face, name, icon, text], i) => {
    const p = pop(frame - at - 4 - i * 3, 15);
    return <div key={face} style={{width: 520, height: 400, background: '#fff', borderRadius: 34, padding: 40, textAlign: 'left', boxShadow: '0 40px 90px rgba(32,42,46,.14)', opacity: p, transform: `translateY(${(1 - p) * 120}px)`}}>
      <div style={{display: 'flex', alignItems: 'center', gap: 18, marginBottom: 26}}>
        <Img src={staticFile(`v2/faces/${face}.png`)} style={{width: 72, height: 72, borderRadius: 99, objectFit: 'cover'}} />
        <div style={{fontFamily: sf, fontSize: 34, fontWeight: 700, color: ink, flex: 1}}>{name}</div>
        <Img src={staticFile(`v2/icons/${icon}.png`)} style={{width: 56, height: 56}} />
      </div>
      <div style={{fontFamily: sf, fontSize: 36, color: ink, lineHeight: 1.32, letterSpacing: '-0.01em'}}>{text}</div>
    </div>;
  })}</div>;
}

const clock = (n: number) => `${Math.floor(n / 60)}:${String(Math.floor(n % 60)).padStart(2, '0')}`;
function Race({at}: {at: number}) {
  const l = useCurrentFrame() - at;
  const t = Math.max(0, l / FPS3 - 0.3);
  const typed = Math.min(129, t * 75), spoken = Math.min(36, t * 75);
  const row = (v: number, label: string, color: string, icon: string) => <div style={{width: 1500, marginBottom: 60}}>
    <div style={{display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 18}}>
      <span style={{fontFamily: sf, fontSize: 56, fontWeight: 600, color: ink, letterSpacing: '-0.03em'}}>{icon} {label}</span>
      <span style={{fontFamily: sf, fontSize: 96, fontWeight: 700, color: ink, fontVariantNumeric: 'tabular-nums', letterSpacing: '-0.04em'}}>{clock(v)}</span>
    </div>
    <div style={{height: 40, borderRadius: 20, background: 'rgba(32,42,46,.08)'}}><div style={{height: '100%', width: `${(v / 129) * 100}%`, borderRadius: 20, background: color}} /></div>
  </div>;
  const win = pop(l - b(3.5), 10);
  return <AbsoluteFill style={{background: paper, alignItems: 'center', justifyContent: 'center'}}>
    <div style={{fontFamily: sf, fontSize: 34, fontWeight: 600, letterSpacing: '.18em', color: mute, marginBottom: 70}}>THE SAME 86 WORDS</div>
    {row(spoken, 'saying it', dot, '')}
    {row(typed, 'typing it at 40 wpm', '#9aa7ae', '')}
    <div style={{fontFamily: sf, fontWeight: 800, fontSize: 210, letterSpacing: '-0.06em', color: dot, opacity: win, transform: `scale(${0.6 + 0.4 * win})`}}>3.6× faster</div>
  </AbsoluteFill>;
}

export function Launch3() {
  const frame = useCurrentFrame();
  const endP = pop(frame - b(T.end), 11);
  return <AbsoluteFill style={{background: paper}}>
    <style>{css}</style>
    <Audio src={staticFile(cut.track)} startFrom={Math.round(cut.offset * FPS3)} volume={f => interpolate(f, [0, 15, LAUNCH3_FRAMES - 45, LAUNCH3_FRAMES], [0, 0.55, 0.55, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'})} />
    <Live />
    <Hook from={b(T.hook)} to={b(T.write)} />
    <Card from={b(T.write)} to={b(T.apps)}><Words at={b(T.write)}>you write all day.</Words></Card>
    <Card from={b(T.apps)} to={b(T.ai)}><Icons at={b(T.apps)} /><Words at={b(T.apps)} size={110} weight={700} delay={6}>in every app.</Words></Card>
    <Card from={b(T.ai)} to={b(T.ai + 2.5)}>
      <div style={{fontFamily: sf, fontSize: 66, color: mute, fontStyle: 'italic', maxWidth: 1500, opacity: pop(frame - b(T.ai))}}>“I hope this message finds you well! I wanted to reach out to circle back regarding…”</div>
      <Words at={b(T.ai)} size={170} delay={10}>ai writing</Words>
    </Card>
    <Card from={b(T.ai + 2.5)} to={b(T.say)}><Words at={b(T.ai + 2.5)} size={230} color={dot}>sounds like ai.</Words><Words at={b(T.ai + 2.5)} size={90} weight={600} color={mute} delay={8}>not like you.</Words></Card>
    <Card from={b(T.say)} to={b(T.messages)} bg={ink}>
      <div style={{width: 130, height: 130, borderRadius: 99, background: dot, transform: `scale(${pop(frame - b(T.say), 8) * (1 + 0.1 * Math.sin(frame / 3))})`, boxShadow: '0 0 90px rgba(238,95,39,.6)'}} />
      <Words at={b(T.say)} size={190} color={paper} delay={5}>hold a key. say it.</Words>
    </Card>
    <Card from={b(T.all)} to={b(T.all + 4)} bg={land}>
      <Float src="msg" at={b(T.all)} w={760} x={-450} y={-210} rot={14} />
      <Float src="slack" at={b(T.all)} w={800} x={440} y={-200} rot={-14} delay={2} />
      <Float src="gmail" at={b(T.all)} w={620} x={-440} y={230} rot={14} delay={4} />
      <Float src="notes" at={b(T.all)} w={720} x={450} y={240} rot={-14} delay={6} />
      <div style={{position: 'absolute', zIndex: 3, background: paper, borderRadius: 48, padding: '14px 70px 36px', boxShadow: '0 40px 120px rgba(32,42,46,.3)', opacity: pop(frame - b(T.all) - 8)}}><Words at={b(T.all)} size={170} delay={8}>everywhere you write.</Words></div>
    </Card>
    <Card from={b(T.all + 4)} to={b(T.learns)}><Montage at={b(T.all + 4)} /></Card>
    <Card from={b(T.learns)} to={b(T.voice)}><Words at={b(T.learns)} size={150}>it learns you</Words><Words at={b(T.learns)} size={150} color={dot} delay={4}>from your own writing.</Words><Words at={b(T.learns)} size={64} weight={600} color={mute} delay={14}>your greetings. your length. your sign-off.</Words></Card>
    <Card from={b(T.voice)} to={b(T.race)}><Words at={b(T.voice)} size={150}>in <span style={{color: dot}}>your</span> voice.</Words><Voices at={b(T.voice)} /></Card>
    <Card from={b(T.everyone)} to={b(T.everyone + 2)}><Words at={b(T.everyone)} size={170}>everyone who writes</Words></Card>
    <Card from={b(T.everyone + 2)} to={b(T.model)}><Words at={b(T.everyone + 2)} size={230} color={dot}>is everyone.</Words></Card>
    <Card from={b(T.model)} to={b(T.end)} bg={ink}>
      <div style={{fontFamily: sf, fontSize: 34, fontWeight: 600, letterSpacing: '.2em', color: 'rgba(249,250,247,.55)', opacity: pop(frame - b(T.model))}}>WHAT WE’RE BUILDING</div>
      <Words at={b(T.model)} size={200} color={paper}>the model of <span style={{color: dot}}>you.</span></Words>
      <Words at={b(T.model)} size={60} weight={500} color="rgba(249,250,247,.75)" delay={12}>our own models that learn your voice, and get better with every message.</Words>
    </Card>
    {frame >= b(T.race) && frame < b(T.everyone) && <Race at={b(T.race)} />}
    <Card from={b(T.end)} to={LAUNCH3_FRAMES + 1} bg={land}>
      <Img src={staticFile('assets/intention-wordmark.svg')} style={{height: 250, opacity: endP, transform: `scale(${0.85 + 0.15 * endP})`}} />
      <Words at={b(T.end)} size={84} font={serif} weight={400} delay={8}>Say what you mean. Keep your voice.</Words>
      <div style={{position: 'absolute', bottom: 64, fontFamily: sf, fontSize: 44, fontWeight: 600, color: ink, opacity: pop(frame - b(T.end) - 20)}}>intention-gray.vercel.app</div>
    </Card>
  </AbsoluteFill>;
}
