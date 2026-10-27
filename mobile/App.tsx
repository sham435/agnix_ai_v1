import { StatusBar } from 'expo-status-bar';
import { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Button,
  FlatList,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { api } from './src/api/client';
import type { Agent, Conversation } from './src/api/types';
import { API_BASE } from './src/config';

type Screen = 'login' | 'loading' | 'home';

export default function App() {
  const [screen, setScreen] = useState<Screen>('loading');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);

  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [agents, setAgents] = useState<Agent[]>([]);

  const loadHome = useCallback(async () => {
    setScreen('loading');
    try {
      const [convs, agts] = await Promise.all([api.listConversations(), api.listAgents()]);
      setConversations(convs);
      setAgents(agts);
      setScreen('home');
    } catch {
      setScreen('login');
    }
  }, []);

  useEffect(() => {
    void loadHome();
  }, [loadHome]);

  const handleLogin = useCallback(async () => {
    setError(null);
    try {
      await api.fetchCsrfToken();
      await api.login(email, password);
      await loadHome();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Login failed.');
    }
  }, [email, password, loadHome]);

  if (screen === 'loading') {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" />
        <Text style={styles.muted}>Connecting to {API_BASE}...</Text>
      </View>
    );
  }

  if (screen === 'login') {
    return (
      <View style={styles.container}>
        <StatusBar style="auto" />
        <Text style={styles.title}>Shams</Text>
        <TextInput
          style={styles.input}
          placeholder="Email"
          autoCapitalize="none"
          keyboardType="email-address"
          value={email}
          onChangeText={setEmail}
        />
        <TextInput
          style={styles.input}
          placeholder="Password"
          secureTextEntry
          value={password}
          onChangeText={setPassword}
        />
        {error ? <Text style={styles.error}>{error}</Text> : null}
        <Button title="Sign in" onPress={handleLogin} />
        <Text style={styles.muted}>{API_BASE}</Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <StatusBar style="auto" />
      <View style={styles.header}>
        <Text style={styles.title}>Shams</Text>
        <Button title="Sign out" onPress={() => void api.logout().then(() => setScreen('login'))} />
      </View>

      <Text style={styles.section}>Active conversations</Text>
      <FlatList
        data={conversations}
        keyExtractor={(item) => String(item.id)}
        renderItem={({ item }) => (
          <View style={styles.row}>
            <Text style={styles.rowTitle}>{item.title || 'Untitled conversation'}</Text>
            <Text style={styles.muted}>{item.agent?.name ?? `Agent #${item.agent_id}`}</Text>
          </View>
        )}
        ListEmptyComponent={<Text style={styles.muted}>No conversations yet.</Text>}
      />

      <Text style={styles.section}>Agents</Text>
      <FlatList
        data={agents}
        keyExtractor={(item) => String(item.id)}
        renderItem={({ item }) => (
          <View style={styles.row}>
            <Text style={styles.rowTitle}>{item.name}</Text>
            <Text style={styles.muted}>
              {item.model} · {item.provider}
            </Text>
          </View>
        )}
        ListEmptyComponent={<Text style={styles.muted}>No agents yet.</Text>}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    paddingTop: 64,
    paddingHorizontal: 16,
  },
  center: {
    flex: 1,
    backgroundColor: '#fff',
    alignItems: 'center',
    justifyContent: 'center',
  },
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 8,
  },
  title: {
    fontSize: 28,
    fontWeight: '700',
  },
  section: {
    fontSize: 16,
    fontWeight: '600',
    marginTop: 12,
    marginBottom: 4,
  },
  input: {
    borderWidth: 1,
    borderColor: '#ccc',
    borderRadius: 8,
    padding: 12,
    marginBottom: 12,
    fontSize: 16,
  },
  error: {
    color: 'red',
    marginBottom: 12,
  },
  row: {
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#ddd',
  },
  rowTitle: {
    fontSize: 16,
    fontWeight: '500',
  },
  muted: {
    fontSize: 13,
    color: '#888',
    marginTop: 2,
  },
});